import CompetitionCore
import SwiftUI

struct CompetitionSharingView: View {
    let publication: LocalCompetitionPublication
    let challengeStatus: CompetitionFeature.ChallengeSheetStatus
    let senderName: String?
    var ownChallengeLink: URL? = nil
    let dismissChallenge: () -> Void
    @Binding var recipientCode: String
    let recipient: CompetitionFeature.InviteRecipient?
    let recipientStatus: CompetitionFeature.InviteRecipientStatus
    var metrics: Binding<CompetitionMetrics>? = nil
    var requestSleepAccess: (() -> Void)? = nil
    let findRecipient: () -> Void
    let createInvite: () -> Void
    @Binding var isChallengePresented: Bool
    var presentsChallengeSheet = true
    var friends: [FriendPerson] = []
    var chooseFriend: ((FriendPerson) -> Void)? = nil
    var searchPeople: (() -> Void)? = nil
    let selectCompetition: (CompetitionID) -> Void
    let openHistory: () -> Void
    let reinvite: () -> Void
    let isReinviteInFlight: Bool
    let challengeAgain: (CompetitionID) -> Void
    let archive: (CompetitionID) -> Void
    let commandIDsInFlight: Set<CompetitionID>
    let retry: () async -> Void
    var practice: CompetitionPracticeStart? = nil
    var isPracticePresented: Binding<Bool> = .constant(false)
    var refresh: (@Sendable () async -> Void)? = nil
    var openRecap: ((CompetitionRecapPeriod) -> Void)? = nil
    var isUpdating = false

    @AppStorage(CompetitionDismissedChallenges.storageKey)
    private var dismissedChallenges = CompetitionDismissedChallenges()
    @AppStorage(CompetitionReactionsSeen.storageKey)
    private var reactionsSeen = CompetitionReactionsSeen()
    @AppStorage(CompetitionMotionSeen.storageKey)
    private var motionSeen = CompetitionMotionSeen()

    @Environment(\.locale) private var locale
    @Environment(\.timeZone) private var timeZone
    @Environment(\.launchStage) private var launchStage

    var body: some View {
        let layout = self.layout
        let records = self.records
        let summary = competitionIssueSummary(
            publication.dashboard.issues,
            attributedIDs: attributedIDs(layout)
        )
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if let summary {
                    issueBanner(summary)
                        .transition(Motion.appear)
                }

                if !layout.needsYou.isEmpty {
                    section("NEEDS YOU", id: "competition.home.needsYou") {
                        rowPanel(layout.needsYou) { competition in
                            rowButton(competition)
                        }
                    }
                }

                if let hero = layout.hero {
                    let belt = beltGoingIn(for: hero, in: records)
                    ZStack {
                        VStack(alignment: .leading, spacing: 12) {
                            competitionButton(hero, caption: homeCaption(beltStanding(belt, hero), hero)) {
                                CompetitionHeroCard(
                                    competition: hero,
                                    source: publication.source,
                                    belt: belt,
                                    reaction: unseen(hero),
                                    isUpdating: isUpdating
                                )
                            }
                            .buttonStyle(CompetitionPressButtonStyle())
                            issueLine(hero)
                        }
                        .id(hero.id)
                        .transition(Motion.appear)
                    }
                    .transition(Motion.appear)
                }

                if !layout.live.isEmpty {
                    section("LIVE · \(layout.live.count)", id: "competition.home.live") {
                        VStack(spacing: 12) {
                            ForEach(layout.live) { competition in
                                let belt = beltGoingIn(for: competition, in: records)
                                VStack(alignment: .leading, spacing: 12) {
                                    competitionButton(
                                        competition,
                                        caption: homeCaption(beltStanding(belt, competition), competition)
                                    ) {
                                        CompetitionHeroCard(
                                            competition: competition,
                                            source: publication.source,
                                            isCompact: true,
                                            belt: belt,
                                            reaction: unseen(competition),
                                            isUpdating: isUpdating
                                        )
                                    }
                                    .buttonStyle(CompetitionPressButtonStyle())
                                    issueLine(competition)
                                }
                                .padding(16)
                                .themePanel()
                                .transition(Motion.appear)
                            }
                        }
                    }
                }

                if !GroupMatchHomeCards.shown(publication.dashboard.groupMatches, now: publication.evaluatedAt).isEmpty {
                    GroupMatchHomeCards(
                        matches: publication.dashboard.groupMatches,
                        now: publication.evaluatedAt,
                        select: selectCompetition
                    )
                        .transition(Motion.appear)
                }

                if !layout.upNext.isEmpty {
                    section("UP NEXT", id: "competition.home.upNext") {
                        rowPanel(layout.upNext) { competition in
                            if competitionIsClosedOutgoing(competition.lifecycle) {
                                CompetitionClosedChallengeRow(
                                    competition: competition,
                                    canChallengeAgain: canChallengeAgain(competition),
                                    isInFlight: publication.source == .simulatedFixture
                                        && isReinviteInFlight,
                                    challengeAgain: { challengeAgain(competition.id) },
                                    dismiss: { dismissedChallenges = dismissedChallenges.dismissing(competition.id) }
                                )
                            } else {
                                rowButton(competition)
                            }
                        }
                    }
                }

                if !layout.recentResults.isEmpty {
                    section("RECENT RESULTS", id: "competition.home.results") {
                        rowPanel(layout.recentResults) { competition in
                            resultRow(competition)
                        }
                    }
                }

                if publication.source == .remoteParticipants,
                   !layout.allItems.isEmpty,
                   layout.allItems.allSatisfy(\.isPractice) {
                    Button("Challenge Someone") {
                        isChallengePresented = true
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .accessibilityIdentifier("competition.practice.challenge")
                    .transition(Motion.appear)
                }

                if layout.isEmpty && GroupMatchHomeCards.shown(publication.dashboard.groupMatches, now: publication.evaluatedAt).isEmpty {
                    emptyState
                        .transition(Motion.appear)
                }

                if let openRecap, let offer = recapOffer {
                    CompetitionRecapRow(
                        title: offer.headline(locale: locale),
                        period: offer,
                        competitions: publication.dashboard.competitions,
                        isPanel: true
                    ) { openRecap(offer) }
                    .buttonStyle(CompetitionPressButtonStyle())
                    .accessibilityIdentifier("competition.recap.open")
                    .transition(Motion.appear)
                }

                if !records.isEmpty {
                    historyButton
                        .transition(Motion.appear)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .moving(Motion.settle, value: layout.shape)
            .moving(Motion.settle, value: GroupMatchHomeCards.shown(publication.dashboard.groupMatches, now: publication.evaluatedAt).map(\.id))
            .moving(Motion.settle, value: publication.dashboard.issues)
            .moving(Motion.settle, value: layout.allItems.map { unseen($0)?.updatedAt })
            .moving(Motion.settle, value: layout.allItems.map { beltGoingIn(for: $0, in: records)?.holder })
            .moving(Motion.settle, value: records.isEmpty)
            .moving(Motion.settle, value: recapOffer)
        }
        .refreshable(refresh)
        .background(Theme.ground)
        .competitionReactionRain(
            incoming: competitionReactionRainBatch(
                layout.allItems, seen: reactionsSeen, motionSeen: motionSeen
            ),
            rained: { motionSeen = motionSeen.raining(layout.allItems) }
        )
        .navigationTitle("Home")
        .navigationBarTitleDisplayMode(.large)
        .sheet(
            isPresented: Binding(
                get: { presentsChallengeSheet && isChallengePresented },
                set: { if presentsChallengeSheet { isChallengePresented = $0 } }
            ),
            onDismiss: dismissChallenge
        ) {
            CreateCompetitionView(
                status: challengeStatus,
                timeZoneIdentifier: publication.timeZoneIdentifier,
                evaluatedAt: publication.evaluatedAt,
                recipientCode: $recipientCode,
                recipient: recipient,
                recipientStatus: recipientStatus,
                metrics: metrics,
                requestSleepAccess: requestSleepAccess,
                senderName: senderName,
                ownChallengeLink: ownChallengeLink,
                friends: friends,
                competitions: publication.dashboard.competitions,
                chooseFriend: chooseFriend,
                searchPeople: searchPeople,
                practice: practice,
                findRecipient: findRecipient,
                create: createInvite,
                openChallenge: {
                    isChallengePresented = false
                    selectCompetition($0)
                }
            )
        }
        .onChange(of: practice?.isStarting) { wasStarting, isStarting in
            if wasStarting == true, isStarting == false, practice?.failed == false {
                isPracticePresented.wrappedValue = false
            }
        }
    }

    private var layout: CompetitionHomeLayout {
        competitionHomeLayout(
            publication.dashboard,
            now: publication.evaluatedAt,
            dismissedChallengeIDs: dismissedChallenges.ids
        )
    }

    private var records: [CompetitionOpponentRecord] {
        competitionOpponentRecords(publication.dashboard.competitions)
    }

    private var recapOffer: CompetitionRecapPeriod? {
        competitionRecapToday(publication).flatMap {
            competitionRecapOffer(publication.dashboard.competitions, today: $0)
        }
    }

    private func beltGoingIn(
        for competition: LocalCompetitionPresentation,
        in records: [CompetitionOpponentRecord]
    ) -> CompetitionBelt? {
        guard !competitionBeltWaitsOnAnEarlierMatch(
            competition,
            in: publication.dashboard.competitions
        ) else { return nil }
        return records.first { $0.opponentIdentity == competition.opponentIdentity }?.belt
    }

    private func beltStanding(
        _ belt: CompetitionBelt?,
        _ competition: LocalCompetitionPresentation
    ) -> String? {
        belt.flatMap {
            competitionBeltChipText($0, opponentName: competition.opponentDisplayName)
        }
    }

    private func unseen(_ competition: LocalCompetitionPresentation) -> CompetitionReaction? {
        competitionUnseenReaction(competition, seen: reactionsSeen)
    }

    private func homeCaption(
        _ caption: String?,
        _ competition: LocalCompetitionPresentation
    ) -> String? {
        let reaction = unseen(competition).map {
            competitionReactionAccessibilityText($0, opponentName: competition.opponentDisplayName)
        }
        let parts = [caption, reaction].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: ". ")
    }

    private func attributedIDs(_ layout: CompetitionHomeLayout) -> Set<CompetitionID> {
        Set(layout.allItems.map(\.id) + [PracticeMatch.startCommandID])
    }

    private func canChallengeAgain(_ competition: LocalCompetitionPresentation) -> Bool {
        publication.source == .simulatedFixture
            || RemoteCompetitionOpponentIdentity.profileID(competition.opponentIdentity) != nil
    }

    private func section<Content: View>(
        _ title: String,
        id: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(title)
                .padding(.horizontal, 4)
            content()
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(id)
        .transition(Motion.appear)
    }

    private func rowPanel<Row: View>(
        _ competitions: [LocalCompetitionPresentation],
        @ViewBuilder row: @escaping (LocalCompetitionPresentation) -> Row
    ) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(competitions.enumerated()), id: \.element.id) { index, competition in
                if index > 0 {
                    CompetitionRowDivider()
                        .transition(Motion.appear)
                }
                VStack(spacing: 0) {
                    row(competition)
                    issueLine(competition, inset: true)
                }
                .transition(Motion.appear)
            }
        }
        .themePanel()
        .clipShape(RoundedRectangle(cornerRadius: 20))
    }

    private func rowButton(_ competition: LocalCompetitionPresentation) -> some View {
        competitionButton(competition) {
            CompetitionSharingRow(
                competition: competition,
                source: publication.source
            )
        }
        .buttonStyle(CompetitionRowButtonStyle())
    }

    @ViewBuilder
    private func resultRow(_ competition: LocalCompetitionPresentation) -> some View {
        if competition.isPractice {
            rowButton(competition)
        } else {
            archivableResultRow(competition)
        }
    }

    @ViewBuilder
    private func archivableResultRow(_ competition: LocalCompetitionPresentation) -> some View {
        CompetitionArchiveSwipeRow(
            id: competition.id,
            isInFlight: commandIDsInFlight.contains(competition.id),
            label: "Archive. \(competition.opponentDisplayName). \(competitionHomeStatusLine(competition, locale: locale, timeZone: timeZone))",
            archive: { archive(competition.id) }
        ) {
            competitionButton(competition, caption: homeCaption(nil, competition)) {
                CompetitionSharingRow(
                    competition: competition,
                    source: publication.source,
                    reaction: unseen(competition)
                )
            }
            .buttonStyle(CompetitionRowButtonStyle())
        }
    }

    @ViewBuilder
    private func issueLine(
        _ competition: LocalCompetitionPresentation,
        inset: Bool = false
    ) -> some View {
        if let issue = competitionRowIssue(competition.id, in: publication.dashboard.issues) {
            CompetitionIssueLine(issue: issue, retry: retry, id: competition.id)
                .padding(.leading, inset ? 70 : 0)
                .padding(.trailing, inset ? 16 : 0)
                .padding(.bottom, inset ? 8 : 0)
                .transition(Motion.appear)
        }
    }

    private func competitionButton<Content: View>(
        _ competition: LocalCompetitionPresentation,
        caption: String? = nil,
        @ViewBuilder label: () -> Content
    ) -> some View {
        Button {
            selectCompetition(competition.id)
        } label: {
            label()
                .contentShape(Rectangle())
                .accessibilityElement(children: .combine)
                .accessibilityLabel(
                    sharingAccessibilitySummary(
                        competition,
                        source: publication.source,
                        locale: locale,
                        timeZone: timeZone
                    ) + (caption.map { ". \($0)" } ?? "")
                )
                .accessibilityHint("Opens this match")
                .accessibilityActivationPoint(.center)
        }
        .modifier(CompetitionProfileAction(route: competitionOwnProfileRoute(for: competition), name: competition.ownerDisplayName))
        .modifier(CompetitionProfileAction(route: competitionProfileRoute(for: competition), name: competition.opponentDisplayName))
        .accessibilityIdentifier(competitionSharingIdentifier(competition))
    }

    private var historyButton: some View {
        Button(action: openHistory) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("History")
                        .font(.headline)
                        .foregroundStyle(Theme.ink)
                    competitionHistorySummary(records)
                        .font(.subheadline)
                        .foregroundStyle(Theme.secondary)
                }
                Spacer(minLength: 8)
                DisclosureChevron()
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
            .themePanel()
            .contentShape(Rectangle())
        }
        .buttonStyle(CompetitionPressButtonStyle())
        .accessibilityLabel("History")
        .accessibilityValue(competitionHistorySummaryAccessibilityText(records))
        .accessibilityHint("Opens finished matches")
        .accessibilityIdentifier("competition.history.open")
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            OpenSlotMark()
                .frame(width: 96)
                .launchLanding(.slot)
                .opacity(launchStage == .done ? 1 : 0)

            VStack(spacing: 6) {
                Text(records.isEmpty ? "No matches yet" : "Nothing live right now")
                    .font(.title3.weight(.heavy).width(.condensed))
                    .foregroundStyle(Theme.ink)
                if let emptyStateDescription {
                    Text(emptyStateDescription)
                        .font(.subheadline)
                        .foregroundStyle(Theme.secondary)
                }
            }
            .multilineTextAlignment(.center)

            if publication.source == .simulatedFixture, canReinvite {
                Button {
                    reinvite()
                } label: {
                    BusyLabel(
                        "Challenge \(LocalCompetitionIdentity.opponentDisplayName) Again",
                        isBusy: isReinviteInFlight
                    )
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(isReinviteInFlight)
                .accessibilityValue(
                    isReinviteInFlight ? "Action in progress" : ""
                )
            }

            if publication.source == .remoteParticipants {
                Button("Challenge Someone") {
                    isChallengePresented = true
                }
                .buttonStyle(PrimaryButtonStyle())
                .accessibilityIdentifier("competition.create.empty")
            }

            if offersPractice {
                Button("Practice Match") {
                    isPracticePresented.wrappedValue = true
                }
                .buttonStyle(SecondaryButtonStyle())
                .accessibilityHint("Opens a practice match against a pacer")
                .accessibilityIdentifier("competition.practice.open")
            }
        }
        .frame(maxWidth: .infinity)
        .padding(20)
        .themePanel()
    }

    private var canReinvite: Bool {
        publication.dashboard.hiddenTerminalCompetitionCount > 0
            || publication.dashboard.competitions.contains {
                switch $0.lifecycle {
                case .declined, .expired, .cancelled: true
                default: false
                }
            }
    }

    private var emptyStateDescription: String? {
        switch publication.source {
        case .simulatedFixture:
            if canReinvite {
                "The last challenge closed. You can challenge \(LocalCompetitionIdentity.opponentDisplayName) again."
            } else {
                records.isEmpty ? "A local challenge will appear here." : nil
            }
        case .remoteParticipants:
            if offersPractice {
                "Challenge someone to a 7-day match, or warm up against a pacer."
            } else {
                records.isEmpty ? "Challenge someone to start a match." : nil
            }
        }
    }

    private var offersPractice: Bool {
        practice != nil && publication.source == .remoteParticipants && records.isEmpty
    }

    private func issueBanner(_ summary: String) -> some View {
        Label(summary, systemImage: "exclamationmark.triangle.fill")
            .font(.subheadline.weight(.medium))
            .foregroundStyle(Theme.ink)
            .contentTransition(.opacity)
            .animation(Motion.fade, value: summary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .themePanel()
            .accessibilityLabel("Match status. \(summary)")
    }
}

struct CompetitionHeroCard: View {
    let competition: LocalCompetitionPresentation
    let source: CompetitionPublicationSource
    var isCompact = false
    var belt: CompetitionBelt? = nil
    var reaction: CompetitionReaction? = nil
    var isUpdating = false

    @Environment(\.locale) private var locale
    @Environment(\.timeZone) private var timeZone

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            statusRow
                .animation(Motion.fade, value: isUpdating)

            if !competitionShouldShowScores(competition.lifecycle),
               let holder = belt?.holder,
               let text = belt.flatMap({
                   competitionBeltChipText($0, opponentName: competition.opponentDisplayName)
               }) {
                CompetitionBeltChip(holder: holder, text: text)
                    .transition(Motion.appear)
            }

            if competitionShouldShowScores(competition.lifecycle) {
                HeroScoreboard(competition: competition, isCompact: isCompact, belt: belt)
                    .transition(Motion.appear)
                statement
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondary)
                    .transition(Motion.appear)
            } else {
                scheduledHeadline
                    .transition(Motion.appear)
            }

            CompetitionHomeWeekStrip(
                days: competition.days,
                currentDayOrdinal: competition.currentDayOrdinal
            )

            if let reaction {
                Divider().overlay(Theme.hairline)
                    .transition(Motion.appear)
                CompetitionReactionLine(
                    reaction: reaction,
                    opponentName: competition.opponentDisplayName
                )
                .transition(Motion.appear)
            }

            if let disclosure = competitionFixtureDisclosure(
                source: source,
                opponentDisplayName: competition.opponentDisplayName
            ) {
                Text(disclosure)
                    .font(.caption)
                    .foregroundStyle(Theme.secondary)
            }

            if !isCompact {
                HStack(spacing: 6) {
                    Text("Match details")
                        .font(.subheadline.weight(.semibold))
                    Image(systemName: "arrow.right")
                        .font(.footnote.weight(.bold))
                }
                .foregroundStyle(Theme.ink)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .moving(Motion.settle, value: leadSide)
    }

    private var statusRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                statusLeading
                Spacer(minLength: 8)
                statusTrailing
            }
            VStack(alignment: .leading, spacing: 4) {
                statusLeading
                statusTrailing
            }
        }
    }

    private var statusLeading: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            titleText
                .fixedSize(horizontal: false, vertical: true)
            CompetitionMetricBadge(metrics: competition.metrics)
        }
    }

    private var titleText: Text {
        let name = Text(competition.opponentDisplayName)
            .font(.headline)
            .foregroundStyle(Theme.ink)
        if competition.isPractice {
            let practice = Text(" · Practice")
                .font(.footnote.weight(.medium))
                .foregroundStyle(Theme.secondary)
            return Text("\(name)\(practice)")
        }
        return name
    }

    @ViewBuilder
    private var statusTrailing: some View {
        if let text = cardStateText {
            Text(text)
                .font(.footnote.weight(.medium))
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var cardStateText: String? {
        if isUpdating { return "Updating…" }
        switch competition.lifecycle {
        case let .active(dayOrdinal):
            return "Day \(dayOrdinal) of 7"
        case .endsToday:
            return "Last day"
        case .tallying:
            if let deadline = competition.tally?.bestAvailableDeadline,
               competition.evaluatedAt < deadline {
                return "Final score by \(competitionDeadlineText(deadline, now: competition.evaluatedAt, locale: locale, timeZone: timeZone))"
            }
            return "Final score pending"
        case .scheduled:
            return status.timing ?? "Scheduled"
        case .completed, .archived:
            return status.timing ?? status.title
        default:
            return status.title
        }
    }

    private var status: CompetitionStatusText {
        competitionStatusText(competition, style: .card, locale: locale, timeZone: timeZone)
    }

    private var margin: Double {
        competitionDisplayedMargin(
            userPoints: competition.userPoints,
            opponentPoints: competition.opponentPoints
        )
    }

    private var leadSide: FloatingPointSign? {
        margin == 0 ? nil : margin.sign
    }

    private var statement: some View {
        ZStack(alignment: .leading) {
            competitionLeadText(
                userPoints: competition.userPoints,
                opponentPoints: competition.opponentPoints,
                opponentDisplayName: competition.opponentDisplayName,
                locale: locale
            )
            .scoreRoll(abs(margin), id: leadSide)
        }
        .animation(Motion.late, value: leadSide)
    }

    private var scheduledHeadline: some View {
        let you = Text("You").foregroundStyle(Theme.you)
        let vs = Text(" vs ").foregroundStyle(Theme.tertiary)
        let opponent = Text(competition.opponentDisplayName)
            .foregroundStyle(Theme.ink)
        return Text("\(you)\(vs)\(opponent)")
            .font(.title3.weight(.bold))
    }
}

private struct CompetitionHomeWeekStrip: View {
    let days: [LocalCompetitionDayPresentation]
    let currentDayOrdinal: Int?

    @Environment(\.locale) private var locale
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.launchStage) private var launchStage

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(days.enumerated()), id: \.element.ordinal) { index, day in
                VStack(spacing: 5) {
                    CompetitionDayBar(outcome: outcome(day), todayColor: leaderColor(day))
                        .frame(height: 8)
                        .scaleEffect(x: launchStage == .waiting ? 0 : 1, anchor: .leading)
                        .moving(Motion.grow(index, of: days.count), value: launchStage)
                    if dynamicTypeSize < .xxLarge {
                        Text(singleLetterWeekday(day.day, locale: locale))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(day.ordinal == currentDayOrdinal ? Theme.ink : Theme.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .animation(Motion.fade, value: days.map(outcome))
        .animation(Motion.fade, value: days.map(leaderColor))
        .accessibilityHidden(true)
    }

    private func outcome(_ day: LocalCompetitionDayPresentation) -> CompetitionDayOutcome {
        competitionDayOutcome(day, currentDayOrdinal: currentDayOrdinal)
    }

    private func leaderColor(_ day: LocalCompetitionDayPresentation) -> Color {
        guard let owner = day.ownerAcceptedPoints,
              let opponent = day.opponentRevealedPoints
        else {
            return Theme.outline
        }
        return competitionDisplayedMargin(userPoints: owner, opponentPoints: opponent) >= 0
            ? Theme.you : Theme.ink
    }

    private func singleLetterWeekday(_ day: CompetitionDay, locale: Locale) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = locale
        guard let date = calendar.date(
            from: DateComponents(year: day.year, month: day.month, day: day.day)
        ) else {
            return ""
        }
        let index = calendar.component(.weekday, from: date) - 1
        return calendar.veryShortWeekdaySymbols[index]
    }
}

private struct HeroScoreboard: View {
    let competition: LocalCompetitionPresentation
    let belt: CompetitionBelt?

    @ScaledMetric private var scoreSize: CGFloat
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.launchStage) private var launchStage

    init(competition: LocalCompetitionPresentation, isCompact: Bool, belt: CompetitionBelt?) {
        self.competition = competition
        self.belt = belt
        _scoreSize = ScaledMetric(wrappedValue: isCompact ? 40 : 64, relativeTo: .largeTitle)
    }

    var body: some View {
        layout {
            side(.you, points: competition.userPoints, color: Theme.you, trailing: false)
            if !isStacked {
                Color.clear
                    .frame(width: 2, height: scoreSize)
                    .launchLanding(.score)
                    .accessibilityHidden(true)
            }
            side(.them, points: competition.opponentPoints, color: Theme.ink, trailing: !isStacked)
        }
    }

    private var isStacked: Bool {
        dynamicTypeSize.isAccessibilitySize
    }

    private var layout: AnyLayout {
        isStacked
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(alignment: .bottom, spacing: 8))
    }

    private func side(
        _ holder: CompetitionBeltHolder,
        points: Double,
        color: Color,
        trailing: Bool
    ) -> some View {
        let shown = launchStage == .waiting ? 0 : points
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            if trailing, belt?.holder == holder {
                beltCount(holder)
            }
            Text(competitionPointsText(shown))
                .font(.score(size: scoreSize).monospacedDigit())
                .scoreRoll(shown, id: competition.id)
            if !trailing, belt?.holder == holder {
                beltCount(holder)
            }
        }
        .foregroundStyle(color)
        .frame(maxWidth: .infinity, alignment: trailing ? .trailing : .leading)
    }

    private func beltCount(_ holder: CompetitionBeltHolder) -> some View {
        HStack(spacing: 4) {
            CompetitionBeltMark(holder: holder)
            let defenses = belt?.current?.defenses ?? 0
            if defenses > 0 {
                Text("×\(defenses)")
                    .font(.caption.weight(.bold).monospacedDigit())
                    .accessibilityHidden(true)
            }
        }
        .fixedSize()
        .transition(Motion.appear)
    }
}

private struct CompetitionSharingRow: View {
    let competition: LocalCompetitionPresentation
    let source: CompetitionPublicationSource
    var showsName = true
    var beltHolder: CompetitionBeltHolder? = nil
    var reaction: CompetitionReaction? = nil
    var opensMatch = true
    var dayMarks: [CompetitionOutcome?]? = nil
    var badgeName: String? = nil

    @ScaledMetric(relativeTo: .headline) private var badgeSize: CGFloat = 40
    @Environment(\.locale) private var locale
    @Environment(\.timeZone) private var timeZone

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            rowContent
            if dayMarks != nil || badgeName != nil {
                HStack(spacing: 8) {
                    if let badgeName {
                        CompetitionBadgeTag(name: badgeName)
                    }
                    Spacer(minLength: 8)
                    if let dayMarks {
                        CompetitionDayMarks(outcomes: dayMarks)
                    }
                }
            }
            if let reaction {
                CompetitionReactionLine(
                    reaction: reaction,
                    opponentName: competition.opponentDisplayName
                )
                .transition(Motion.appear)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
    }

    private var rowContent: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) {
                badge
                identity
                Spacer(minLength: 8)
                if let beltHolder {
                    CompetitionBeltMark(holder: beltHolder)
                }
                if competitionShouldShowScores(competition.lifecycle) {
                    trailingScore
                }
                trailingMark
            }

            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: showsName ? .top : .center, spacing: 14) {
                    badge
                    identity
                    Spacer(minLength: 0)
                    if !hasScoreRow {
                        trailingMark
                            .frame(minHeight: badgeSize)
                    }
                }
                if hasScoreRow {
                    HStack {
                        if competitionShouldShowScores(competition.lifecycle) {
                            trailingScore
                        }
                        Spacer()
                        if let beltHolder {
                            CompetitionBeltMark(holder: beltHolder)
                        }
                        trailingMark
                    }
                }
            }
        }
    }

    private var hasScoreRow: Bool {
        beltHolder != nil || competitionShouldShowScores(competition.lifecycle)
    }

    @ViewBuilder
    private var badge: some View {
        if let outcome = sharingOutcome(competition.lifecycle) {
            CompetitionOutcomeChip(outcome: outcome)
        } else {
            PersonAvatar(
                name: competition.opponentDisplayName,
                photo: competition.opponentProfileID,
                size: badgeSize
            )
        }
    }

    private var identity: some View {
        VStack(alignment: .leading, spacing: 4) {
            if showsName {
                Text(competition.opponentDisplayName)
                    .font(.headline)
                    .foregroundStyle(Theme.ink)
            }
            Text(statusText)
                .font(showsName ? .subheadline.weight(.medium) : .headline)
                .foregroundStyle(statusColor)
            if let disclosure = competitionFixtureDisclosure(
                source: source,
                opponentDisplayName: competition.opponentDisplayName
            ) {
                Text(disclosure)
                    .font(.caption)
                    .foregroundStyle(Theme.secondary)
            }
        }
        .multilineTextAlignment(.leading)
    }

    private var statusText: String {
        if sharingOutcome(competition.lifecycle) != nil,
           let timing = competitionStatusText(competition, style: .row, locale: locale, timeZone: timeZone).timing {
            return competition.isPractice ? "Practice · \(timing)" : timing
        }
        return competitionHomeStatusLine(competition, locale: locale, timeZone: timeZone)
    }

    private var statusColor: Color {
        showsName ? Theme.secondary : Theme.ink
    }

    private var trailingScore: some View {
        let digits = sharingFractionDigits(competition)
        let you = Text(competitionPointsText(competition.userPoints, fractionDigits: digits, locale: locale))
            .foregroundStyle(Theme.you)
        let slash = Text(" / ").foregroundStyle(Theme.faint)
        let them = Text(competitionPointsText(competition.opponentPoints, fractionDigits: digits, locale: locale))
            .foregroundStyle(Theme.ink)
        return Text("\(you)\(slash)\(them)")
            .font(.title3.weight(.heavy).width(.condensed).monospacedDigit())
    }

    @ViewBuilder
    private var trailingMark: some View {
        if case .pending(.incoming, _, _) = competition.lifecycle {
            Text("Review")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.onInk)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Theme.ink, in: Capsule())
                .accessibilityHidden(true)
        } else if opensMatch {
            DisclosureChevron()
        }
    }
}

private struct CompetitionOutcomeChip: View {
    let outcome: CompetitionOutcome

    @ScaledMetric(relativeTo: .headline) private var size: CGFloat = 32

    var body: some View {
        Text(letter)
            .font(.headline.weight(.heavy).width(.condensed))
            .foregroundStyle(foreground)
            .padding(4)
            .frame(minWidth: size, minHeight: size)
            .background(fill, in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                if outcome == .tie {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Theme.outline, lineWidth: 1.5)
                }
            }
            .accessibilityHidden(true)
    }

    private var letter: String {
        switch outcome {
        case .win: "W"
        case .loss: "L"
        case .tie: "T"
        }
    }

    private var fill: Color {
        switch outcome {
        case .win: Theme.youFill
        case .loss: Theme.ink
        case .tie: .clear
        }
    }

    private var foreground: Color {
        switch outcome {
        case .win: Theme.onYouFill
        case .loss: Theme.onInk
        case .tie: Theme.ink
        }
    }
}

struct CompetitionBeltHeroArt: View {
    let holder: CompetitionBeltHolder

    var body: some View {
        Image(decorative: holder == .you ? "BeltHeroGold" : "BeltHeroPewter")
            .interpolation(.high)
            .resizable()
            .scaledToFit()
            .padding(.horizontal, 8)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity)
            .background { Theme.beltWell }
            .accessibilityHidden(true)
    }
}

struct CompetitionBeltMark: View {
    let holder: CompetitionBeltHolder
    var width: CGFloat = 34

    var body: some View {
        Image(decorative: holder == .you ? "BeltHeroGold" : "BeltHeroPewter")
            .interpolation(.high)
            .resizable()
            .scaledToFit()
            .frame(width: width, height: width * 447 / 1400)
            .fixedSize()
            .accessibilityHidden(true)
    }
}

struct CompetitionDefensePips: View {
    let count: Int
    var lit: Int? = nil
    let color: Color

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<min(count, 12), id: \.self) { index in
                SlantedBar()
                    .fill(index < lit ?? count ? color : Theme.track)
                    .frame(width: 7, height: 18)
            }
        }
        .accessibilityHidden(true)
    }
}

private struct CompetitionBeltChip: View {
    let holder: CompetitionBeltHolder
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            CompetitionBeltMark(holder: holder)
            Text(text)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(holder == .you ? Theme.you : Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(.opacity)
        }
        .animation(Motion.fade, value: text)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Theme.ground, in: chipShape)
        .overlay { chipShape.strokeBorder(Theme.hairline) }
    }

    private var chipShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 12)
    }
}

private struct CompetitionClosedChallengeRow: View {
    let competition: LocalCompetitionPresentation
    let canChallengeAgain: Bool
    let isInFlight: Bool
    let challengeAgain: () -> Void
    let dismiss: () -> Void

    @ScaledMetric(relativeTo: .headline) private var badgeSize: CGFloat = 40
    @Environment(\.locale) private var locale
    @Environment(\.timeZone) private var timeZone

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 14) {
                PersonAvatar(
                    name: competition.opponentDisplayName,
                    photo: competition.opponentProfileID,
                    size: badgeSize
                )
                VStack(alignment: .leading, spacing: 4) {
                    Text(text?.title ?? competition.opponentDisplayName)
                        .font(.headline)
                        .foregroundStyle(Theme.ink)
                    if let line = text?.line {
                        Text(line)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Theme.secondary)
                    }
                }
                .multilineTextAlignment(.leading)
                .frame(minHeight: 44, alignment: .topLeading)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(
                    text.map { "\($0.title). \($0.line)." } ?? competition.opponentDisplayName
                )
                .accessibilityAddTraits(.isStaticText)
                Spacer(minLength: 0)
                Button(action: dismiss) {
                    Image(systemName: "xmark")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(Theme.secondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .padding(.top, -10)
                .padding(.trailing, -10)
                .accessibilityLabel("Dismiss")
                .accessibilityHint("Removes this from Home")
                .accessibilityIdentifier("competition.closedRow.dismiss.\(uuid)")
            }

            if canChallengeAgain {
                Button(action: challengeAgain) {
                    BusyLabel(
                        "Challenge \(competition.opponentDisplayName) Again",
                        isBusy: isInFlight
                    )
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(isInFlight)
                .accessibilityIdentifier("competition.closedRow.again.\(uuid)")
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(competitionSharingIdentifier(competition))
    }

    private var text: (title: String, line: String)? {
        competitionClosedChallengeText(competition, locale: locale, timeZone: timeZone)
    }

    private var uuid: String {
        competition.id.rawValue.uuidString.lowercased()
    }
}

private struct CompetitionArchiveSwipeRow<Row: View>: View {
    let id: CompetitionID
    let isInFlight: Bool
    let label: String
    let archive: () -> Void
    @ViewBuilder let row: Row

    @ScaledMetric private var actionWidth: CGFloat = 96

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 0) {
                row
                    .containerRelativeFrame(.horizontal)
                Button(action: archive) {
                    BusyLabel("Archive", isBusy: isInFlight)
                        .font(.subheadline.weight(.semibold))
                        .tint(Theme.onInk)
                        .foregroundStyle(Theme.onInk)
                        .frame(width: actionWidth)
                        .frame(maxHeight: .infinity)
                        .background(Theme.ink)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isInFlight)
                .accessibilityLabel(label)
                .accessibilityHint("Moves this result to History")
                .accessibilityIdentifier("competition.archive.\(id.rawValue.uuidString.lowercased())")
            }
            .fixedSize(horizontal: false, vertical: true)
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.viewAligned)
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.basedOnSize)
    }
}

struct CompetitionIssueLine: View {
    let issue: CompetitionRowIssue
    let retry: (() async -> Void)?
    let id: CompetitionID

    @State private var isRetrying = false

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Label(text, systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Theme.ink)
                .frame(minHeight: 44, alignment: .leading)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(text)
                .accessibilityAddTraits(.isStaticText)
                .accessibilityIdentifier("competition.issue.\(uuid)")
            Spacer(minLength: 8)
            if issue != .command, let retry {
                Button {
                    Task {
                        isRetrying = true
                        await retry()
                        isRetrying = false
                    }
                } label: {
                    Group {
                        if isRetrying {
                            ProgressView()
                                .waitingFade()
                        } else {
                            Text("Retry")
                                .font(.subheadline.weight(.semibold))
                        }
                    }
                    .foregroundStyle(Theme.ink)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isRetrying)
                .accessibilityLabel("Retry")
                .accessibilityIdentifier("competition.issue.retry.\(uuid)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var text: String {
        switch issue {
        case .command: "Couldn’t finish that. Try again."
        case .refresh: "Couldn’t update scores"
        case .activity: "Couldn’t read your Activity"
        }
    }

    private var uuid: String {
        id.rawValue.uuidString.lowercased()
    }
}

private func competitionHistorySummary(_ records: [CompetitionOpponentRecord]) -> Text {
    let shown = Array(records.prefix(2))
    var text = Text("")
    for (index, record) in shown.enumerated() {
        let entry = Text("\(Text(verbatim: "\(record.opponentDisplayName) "))\(competitionRecordText(record))")
        if index == 0 {
            text = entry
        } else {
            text = Text("\(text) · \(entry)")
        }
    }
    if records.count > 2 {
        text = Text("\(text) · \(records.count - 2) more")
    }
    return text
}

func competitionRecordText(_ record: CompetitionOpponentRecord) -> Text {
    competitionRecordText(wins: record.wins, losses: record.losses, ties: record.ties)
}

func competitionRecordText(wins: Int, losses: Int, ties: Int) -> Text {
    let winsText = Text(String(wins)).foregroundStyle(Theme.you).bold()
    let lossesText = Text(String(losses)).foregroundStyle(Theme.ink)
    if ties > 0 {
        let tiesText = Text(String(ties)).foregroundStyle(Theme.secondary)
        return Text("\(winsText)–\(lossesText)–\(tiesText)")
    }
    return Text("\(winsText)–\(lossesText)")
}

private struct CompetitionRecordRow: View {
    let record: CompetitionOpponentRecord

    @ScaledMetric(relativeTo: .headline) private var badgeSize: CGFloat = 40
    @Environment(\.locale) private var locale
    @Environment(\.timeZone) private var timeZone
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                stackedContent
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 14) {
                        badge
                        identity
                        Spacer(minLength: 8)
                        recordText
                    }
                    stackedContent
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            [record.accessibilityText, beltAccessibilityText, "Latest: \(spokenLine)"]
                .compactMap { $0 }
                .joined(separator: ". ")
        )
        .accessibilityHint("Opens your weeks with \(record.opponentDisplayName)")
    }

    private var stackedContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 14) {
                badge
                identity
                Spacer(minLength: 0)
            }
            recordText
        }
    }

    private var beltAccessibilityText: String? {
        guard let current = record.belt.current, let holder = record.belt.holder else {
            return nil
        }
        return "\(competitionBeltStandingText(holder, opponentName: record.opponentDisplayName)), \(competitionWeeksText(current.weeks))"
    }

    private var badge: some View {
        PersonAvatar(
            name: record.opponentDisplayName,
            photo: record.latest.opponentProfileID,
            size: badgeSize
        )
    }

    private var identity: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(record.opponentDisplayName)
                .font(.headline)
                .foregroundStyle(Theme.ink)
            Text(line)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Theme.secondary)
        }
        .multilineTextAlignment(.leading)
    }

    private var recordText: some View {
        HStack(spacing: 8) {
            if let holder = record.belt.holder {
                CompetitionBeltMark(holder: holder)
            }
            competitionRecordText(record)
                .font(.title3.weight(.heavy).width(.condensed).monospacedDigit())
            DisclosureChevron()
        }
    }

    private var line: String {
        competitionStatusText(record.latest, style: .row, locale: locale, timeZone: timeZone).timing ?? spokenLine
    }

    private var spokenLine: String {
        competitionHomeStatusLine(record.latest, locale: locale, timeZone: timeZone)
    }
}

struct CompetitionHistoryView: View {
    let publication: LocalCompetitionPublication
    var openRecap: ((CompetitionRecapPeriod) -> Void)? = nil
    var openMatch: ((CompetitionID, Int?) -> Void)? = nil

    @State private var filter = CompetitionWeekFilter.all
    @State private var person: String?
    @State private var isCalendarPresented = false
    @Environment(\.locale) private var locale
    @Environment(\.timeZone) private var timeZone

    var body: some View {
        let weeks = competitionHistoryWeeks(publication.dashboard.competitions)
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if weeks.isEmpty && GroupMatchRecord.finished(publication.dashboard.groupMatches).isEmpty {
                    Text("Finished matches appear here.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    if !weeks.isEmpty { recordSection(weeks) }
                    GroupMatchRecord(matches: publication.dashboard.groupMatches, now: publication.evaluatedAt)
                    if let openRecap,
                       let today = competitionRecapToday(publication),
                       case let periods = competitionRecapPeriods(publication.dashboard.competitions, today: today),
                       !periods.isEmpty {
                        recapSection(periods, open: openRecap)
                    }
                    if !weeks.isEmpty { weeksSection(weeks) }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(Theme.ground)
        .navigationTitle("History")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !weeks.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { isCalendarPresented = true } label: {
                        Image(systemName: "calendar")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.ink)
                    }
                    .accessibilityLabel("Match calendar")
                    .accessibilityIdentifier("competition.history.calendar")
                }
            }
        }
        .sheet(isPresented: $isCalendarPresented) {
            CompetitionHistoryCalendarSheet(
                competitions: publication.dashboard.competitions,
                now: publication.evaluatedAt,
                openMatch: { id, dayOrdinal in openMatch?(id, dayOrdinal) }
            )
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            .presentationBackground(Theme.ground)
        }
    }

    private func recordSection(_ weeks: [LocalCompetitionPresentation]) -> some View {
        let records = competitionOpponentRecords(publication.dashboard.competitions)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                SectionLabel("RECORD")
                Spacer(minLength: 8)
                Text(weeks.count == 1 ? "1 WEEK" : "\(weeks.count) WEEKS")
                    .themeLabel()
                    .foregroundStyle(Theme.secondary)
            }
            .padding(.horizontal, 4)

            VStack(spacing: 0) {
                ForEach(Array(records.enumerated()), id: \.element.opponentIdentity) { index, record in
                    if index > 0 {
                        CompetitionRowDivider()
                    }
                    NavigationLink(
                        value: CompetitionHomeRoute.person(record.opponentIdentity)
                    ) {
                        CompetitionRecordRow(record: record)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(CompetitionRowButtonStyle())
                    .accessibilityIdentifier(
                        "competition.record.\(record.latest.id.rawValue.uuidString.lowercased())"
                    )
                }
            }
            .themePanel()
            .clipShape(RoundedRectangle(cornerRadius: 20))
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("competition.rivalry")
    }

    private func recapSection(
        _ periods: [CompetitionRecapPeriod],
        open: @escaping (CompetitionRecapPeriod) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("RECAPS")
                .padding(.horizontal, 4)
            VStack(spacing: 0) {
                ForEach(Array(periods.enumerated()), id: \.element) { index, period in
                    if index > 0 {
                        CompetitionRowDivider(inset: 16)
                    }
                    CompetitionRecapRow(
                        title: period.title(locale: locale),
                        period: period,
                        competitions: publication.dashboard.competitions
                    ) { open(period) }
                    .buttonStyle(CompetitionRowButtonStyle())
                    .accessibilityIdentifier("competition.recap.\(period.year)-\(period.month ?? 0)")
                }
            }
            .themePanel()
            .clipShape(RoundedRectangle(cornerRadius: 20))
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("competition.recaps")
    }

    private func weeksSection(_ weeks: [LocalCompetitionPresentation]) -> some View {
        let records = competitionOpponentRecords(publication.dashboard.competitions)
        let book = competitionBadgeBook(publication.dashboard.competitions)
        let shown = competitionFilteredWeeks(weeks, filter: filter, person: person)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                SectionLabel("WEEKS")
                Spacer(minLength: 8)
                if shown.count < weeks.count {
                    Text("\(shown.count) OF \(weeks.count)")
                        .themeLabel()
                        .foregroundStyle(Theme.secondary)
                        .accessibilityIdentifier("competition.history.shown")
                }
            }
            .padding(.horizontal, 4)

            if weeks.count > 3 {
                weekFilters(records)
            }

            if shown.isEmpty {
                Text("No weeks match.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondary)
                    .padding(.horizontal, 4)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { index, competition in
                        if index > 0 {
                            CompetitionRowDivider()
                        }
                        weekRow(competition, badge: book.byWeek[competition.id]?.first?.name)
                    }
                }
                .themePanel()
                .clipShape(RoundedRectangle(cornerRadius: 20))
            }
        }
    }

    private func weekRow(_ competition: LocalCompetitionPresentation, badge: String?) -> some View {
        let days = competitionDayOutcomes(competition)
        return NavigationLink(
            value: CompetitionHomeRoute.competition(competition.id)
        ) {
            CompetitionSharingRow(
                competition: competition,
                source: publication.source,
                dayMarks: days,
                badgeName: badge
            )
            .contentShape(Rectangle())
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                sharingAccessibilitySummary(
                    competition,
                    source: publication.source,
                    locale: locale,
                    timeZone: timeZone
                )
                    + ". You won \(days.filter { $0 == .win }.count) of \(days.count) days"
                    + (badge.map { ". \($0) badge" } ?? "")
            )
            .accessibilityHint("Opens this match")
        }
        .buttonStyle(CompetitionRowButtonStyle())
        .accessibilityIdentifier(competitionSharingIdentifier(competition))
    }

    private func weekFilters(_ records: [CompetitionOpponentRecord]) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                outcomePicker
                if records.count > 1 { personMenu(records) }
            }
            VStack(alignment: .leading, spacing: 8) {
                outcomePicker
                if records.count > 1 { personMenu(records) }
            }
        }
    }

    private var outcomePicker: some View {
        CompetitionSegments(
            selection: $filter, options: CompetitionWeekFilter.allCases.map { (value: $0, title: $0.title) }
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Show")
        .accessibilityIdentifier("competition.history.filter")
    }

    private func personMenu(_ records: [CompetitionOpponentRecord]) -> some View {
        let name = records.first { $0.opponentIdentity == person }?.opponentDisplayName
        return Menu {
            Picker("With", selection: $person) {
                Text("Everyone").tag(String?.none)
                ForEach(records, id: \.opponentIdentity) {
                    Text($0.opponentDisplayName).tag(String?.some($0.opponentIdentity))
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(name ?? "Everyone")
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.bold))
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 12)
            .frame(minHeight: 32)
            .background(Theme.control, in: RoundedRectangle(cornerRadius: 9))
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .accessibilityLabel("With \(name ?? "everyone")")
        .accessibilityIdentifier("competition.history.person")
    }
}

struct CompetitionPersonView: View {
    let publication: LocalCompetitionPublication
    let opponentIdentity: String
    var cameFrom: CompetitionID? = nil
    var isBlocked: Bool? = false
    var unblock: (() -> Void)? = nil
    var muteButton: CompetitionMuteButton? = nil
    var challenge: ((CompetitionID) -> Void)? = nil
    var friend: PersonFriendControls? = nil
    var drawerBack: (() -> Void)? = nil

    @AppStorage(CompetitionMotionSeen.storageKey)
    private var motionSeen = CompetitionMotionSeen()
    @AppStorage(CompetitionDismissedChallenges.storageKey)
    private var dismissedChallenges = CompetitionDismissedChallenges()
    @State private var showsAllWeeks = false
    @State private var friendDialog: PersonFriendDialog?
    @State private var isBlocking = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @Environment(\.timeZone) private var timeZone
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .largeTitle) private var recordSize: CGFloat = 64
    @ScaledMetric(relativeTo: .largeTitle) private var avatarSize: CGFloat = 56
    @ScaledMetric(relativeTo: .title2) private var tapeValueSize: CGFloat = 21

    var body: some View {
        let competitions = publication.dashboard.competitions
        let theirs = competitions.filter { $0.opponentIdentity == opponentIdentity }
        let record = competitionOpponentRecords(competitions)
            .first { $0.opponentIdentity == opponentIdentity }
        let oldestFirst = competitionRivalryWeeks(competitions, opponentIdentity: opponentIdentity)
        let unseen = competitionUnseenResult(oldestFirst, now: publication.evaluatedAt, seen: motionSeen)
        let name = record?.opponentDisplayName ?? ""
        let button = isLedger(record) || isFromChallenge
            ? nil
            : competitionPersonButtonTitle(
                theirs.filter { !dismissedChallenges.contains($0.id) },
                opponentName: name,
                now: publication.evaluatedAt,
                unseenResult: unseen
            )
        let showsMore = !isDeleted(record)
            && (muteButton != nil || friend != nil || (isBlocked == true && unblock != nil))
        VStack(spacing: 0) {
            if let drawerBack {
                CompetitionDrawerHeader(title: name, back: drawerBack) {
                    if showsMore {
                        personMoreMenu(name: name, usesDrawerStyle: true)
                    }
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    PersonFriendNotes(failure: friend?.failure, isReported: friend?.isReported == true)
                        .padding(.horizontal, 4)
                    if let record, !oldestFirst.isEmpty {
                        content(record, oldestFirst: oldestFirst, theirs: theirs, unseen: unseen)
                        if let button, dynamicTypeSize.isAccessibilitySize {
                            footButton(button, record: record)
                        }
                    } else {
                        Text("Finished matches appear here.")
                            .font(.subheadline)
                            .foregroundStyle(Theme.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("competition.person")
                .environment(\.openCompetitionProfile, nil)
            }
        }
        .background(Theme.ground)
        .safeAreaInset(edge: .bottom) {
            if let button, let record, !dynamicTypeSize.isAccessibilitySize {
                footButton(button, record: record)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 8)
                    .background(Theme.ground)
            }
        }
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if drawerBack == nil, showsMore {
                ToolbarItem(placement: .topBarTrailing) {
                    personMoreMenu(name: name, usesDrawerStyle: false)
                }
            }
        }
        .personFriendDialogs($friendDialog, name: name, controls: friend) { isBlocking = true }
        .moving(Motion.settle, value: friend?.failure)
        .moving(Motion.settle, value: friend?.isReported)
        .onChange(of: isBlocked) { _, blocked in
            if isBlocking, blocked == true { dismiss() }
        }
    }

    private func personMoreMenu(name: String, usesDrawerStyle: Bool) -> some View {
        Menu {
            if let muteButton {
                muteButton
            }
            PersonFriendMenuItems(
                name: name,
                controls: friend,
                isBlocked: isBlocked,
                unblock: unblock,
                dialog: $friendDialog
            )
        } label: {
            if usesDrawerStyle {
                CompetitionDrawerMoreLabel()
            } else {
                CompetitionMoreLabel()
            }
        }
        .accessibilityIdentifier("competition.more")
    }

    @ViewBuilder
    private func content(
        _ record: CompetitionOpponentRecord,
        oldestFirst: [LocalCompetitionPresentation],
        theirs: [LocalCompetitionPresentation],
        unseen: CompetitionID?
    ) -> some View {
        let name = record.opponentDisplayName
        let pieces = competitionRivalryPieces(weeks: oldestFirst.count, isLedger: isLedger(record))
        let now = isFromChallenge || isLedger(record)
            ? nil
            : competitionPersonNow(
                theirs.filter { !dismissedChallenges.contains($0.id) },
                now: publication.evaluatedAt,
                unseenResult: unseen
            )
        let belt = competitionPersonBelt(oldestFirst, holdingBack: unseen, isRetired: record.belt.isRetired)
        let weeks = oldestFirst.reversed().filter { $0.id != now?.competition.id }

        header(record, weekCount: oldestFirst.count)
        if pieces.form {
            CompetitionFormStrip(
                outcomes: oldestFirst.compactMap(\.terminalResult?.outcome),
                opponentName: name,
                isLive: theirs.contains {
                    switch $0.lifecycle {
                    case .active, .endsToday, .tallying: true
                    default: false
                    }
                }
            )
        }
        if let now {
            topCard(now.competition, section: now.section)
        } else if isBlocked == true, !isDeleted(record) {
            quietLine("\(name) can’t challenge you.")
        } else if !isLedger(record), let last = oldestFirst.last,
                  let text = competitionLastPlayedText(last, now: publication.evaluatedAt, locale: locale) {
            quietLine(text)
        }
        beltPanel(belt, name: name, weeks: oldestFirst, showsTape: pieces.tape)
        if pieces.rings, let rings = competitionRingRecords(oldestFirst) {
            CompetitionRingRecordPanel(records: rings, opponentName: name)
        }
        if pieces.records {
            NavigationLink(value: CompetitionHomeRoute.records(opponentIdentity)) {
                HStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Records")
                            .font(.headline)
                            .foregroundStyle(Theme.ink)
                        Text("Best week, closest finish, weekly points")
                            .font(.subheadline)
                            .foregroundStyle(Theme.secondary)
                    }
                    Spacer(minLength: 8)
                    DisclosureChevron()
                }
                .padding(16)
                .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
                .themePanel()
                .contentShape(Rectangle())
            }
            .buttonStyle(CompetitionPressButtonStyle())
            .accessibilityHint("Opens best week, closest finish and weekly points")
            .accessibilityIdentifier("competition.person.records")
        }
        weeksSection(record, belt: belt, weeks: weeks, shown: pieces.weeksShown)
    }

    private func isLedger(_ record: CompetitionOpponentRecord?) -> Bool {
        isBlocked != false || isDeleted(record)
    }

    private func isDeleted(_ record: CompetitionOpponentRecord?) -> Bool {
        record?.belt.isRetired == true
    }

    private var isFromChallenge: Bool {
        guard let cameFrom,
              let match = publication.dashboard.competitions.first(where: { $0.id == cameFrom }),
              case .pending = match.lifecycle
        else { return false }
        return true
    }

    private func avatar(_ record: CompetitionOpponentRecord) -> some View {
        PersonAvatar(
            name: record.opponentDisplayName,
            photo: isLedger(record) ? nil : record.latest.opponentProfileID,
            size: avatarSize,
            initialFont: .title2.weight(.heavy).width(.condensed)
        )
    }

    private func quietLine(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(Theme.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
            .accessibilityIdentifier("competition.person.quiet")
    }

    private func footButton(_ title: String, record: CompetitionOpponentRecord) -> some View {
        Button(title) { challenge?(record.latest.id) }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(challenge == nil)
            .accessibilityIdentifier("competition.person.challenge")
    }

    @ViewBuilder
    private func topCard(
        _ competition: LocalCompetitionPresentation,
        section: String
    ) -> some View {
        let opens = competition.id != cameFrom
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(section)
                .padding(.horizontal, 4)
            Group {
                if competitionIsClosedOutgoing(competition.lifecycle) {
                    CompetitionClosedChallengeRow(
                        competition: competition,
                        canChallengeAgain: false,
                        isInFlight: false,
                        challengeAgain: {},
                        dismiss: { dismissedChallenges = dismissedChallenges.dismissing(competition.id) }
                    )
                } else if section == "THIS WEEK" {
                    let waiting = competition.tally.map {
                        competitionTallyCopy(
                            $0,
                            opponentDisplayName: competition.opponentDisplayName,
                            now: competition.evaluatedAt,
                            locale: locale,
                            timeZone: timeZone
                        ).headline + "."
                    }
                    topLink(competition, opens: opens, spokenAfter: waiting.map { "Provisional. \($0)" }) {
                        VStack(alignment: .leading, spacing: 16) {
                            CompetitionHeroCard(
                                competition: competition,
                                source: publication.source,
                                isCompact: !opens
                            )
                            if let waiting {
                                provisionalLayout {
                                    CompetitionProvisionalTag()
                                    Text(waiting)
                                        .font(.subheadline)
                                        .foregroundStyle(Theme.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .transition(Motion.appear)
                            }
                        }
                        .padding(16)
                    }
                } else {
                    topLink(competition, opens: opens) {
                        CompetitionSharingRow(
                            competition: competition,
                            source: publication.source,
                            showsName: false,
                            opensMatch: opens
                        )
                    }
                }
            }
            .themePanel()
            .clipShape(RoundedRectangle(cornerRadius: 20))
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("competition.person.now")
        .transition(Motion.appear)
    }

    @ViewBuilder
    private func topLink<Content: View>(
        _ competition: LocalCompetitionPresentation,
        opens: Bool,
        spokenAfter: String? = nil,
        @ViewBuilder label: () -> Content
    ) -> some View {
        let summary = [
            sharingAccessibilitySummary(
                competition, source: publication.source, locale: locale, timeZone: timeZone
            ),
            spokenAfter,
        ].compactMap { $0 }.joined(separator: ". ")
        if opens {
            NavigationLink(value: CompetitionHomeRoute.competition(competition.id)) {
                label()
                    .contentShape(Rectangle())
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(summary)
                    .accessibilityHint("Opens this match")
            }
            .buttonStyle(CompetitionRowButtonStyle())
            .accessibilityIdentifier(competitionSharingIdentifier(competition))
        } else {
            label()
                .accessibilityElement(children: .combine)
                .accessibilityLabel(summary)
                .accessibilityIdentifier(competitionSharingIdentifier(competition))
        }
    }

    private var rowLayout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 14))
    }

    private var provisionalLayout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 8))
    }

    private var holdLayout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(alignment: .bottom, spacing: 12))
    }

    private func header(_ record: CompetitionOpponentRecord, weekCount: Int) -> some View {
        let username = isLedger(record) ? nil : friend?.person.username
        let tag = isBlocked == true && !isDeleted(record) ? "Blocked" : muteButton?.isMuted == true ? "Muted" : nil
        return rowLayout {
            avatar(record)
            competitionRecordText(record)
                .font(.score(size: recordSize).monospacedDigit())
            if !dynamicTypeSize.isAccessibilitySize {
                Spacer(minLength: 8)
            }
            VStack(alignment: dynamicTypeSize.isAccessibilitySize ? .leading : .trailing, spacing: 4) {
                Text(competitionWeeksText(weekCount).uppercased())
                if let tag {
                    Text(tag.uppercased())
                }
                if let username {
                    Text(verbatim: "@\(username)")
                        .tracking(0)
                }
            }
            .themeLabel()
            .foregroundStyle(Theme.secondary)
        }
        .padding(.horizontal, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            ["\(record.accessibilityText)", competitionWeeksText(weekCount), tag, username.map { "@\($0)" }]
                .compactMap { $0 }
                .joined(separator: ". ")
        )
        .accessibilityIdentifier("competition.person.record")
    }

    private func beltPanel(
        _ belt: CompetitionBelt,
        name: String,
        weeks: [LocalCompetitionPresentation],
        showsTape: Bool
    ) -> some View {
        let tape = showsTape && belt.changes > 0 && !belt.isRetired ? competitionTaleOfTheTape(belt) : []
        let title = competitionBeltTitle(belt, name: name)
        let since = belt.holder == nil ? nil : belt.current.flatMap { sinceText($0, weeks: weeks) }
        let defenses = belt.holder == nil ? 0 : belt.current?.defenses ?? 0
        return VStack(alignment: .leading, spacing: 12) {
            if let holder = belt.holder {
                CompetitionBeltHeroArt(holder: holder)
            }
            VStack(alignment: .leading, spacing: 12) {
                holdLayout {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title)
                            .font(.headline)
                            .foregroundStyle(belt.holder == .you ? Theme.you : Theme.ink)
                        if let since {
                            Text(since)
                                .font(.subheadline)
                                .foregroundStyle(Theme.secondary)
                        }
                    }
                    if defenses > 0 {
                        if !dynamicTypeSize.isAccessibilitySize {
                            Spacer(minLength: 0)
                        }
                        VStack(alignment: dynamicTypeSize.isAccessibilitySize ? .leading : .trailing, spacing: 4) {
                            CompetitionDefensePips(
                                count: defenses,
                                color: belt.holder == .you ? Theme.youFill : Theme.ink
                            )
                            Text(competitionDefensesText(defenses).uppercased())
                                .themeLabel()
                                .foregroundStyle(Theme.secondary)
                        }
                    }
                }
                if !tape.isEmpty, let latest = weeks.last {
                    taleOfTheTape(tape, name: name, latest: latest)
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.top, belt.holder == nil ? 16 : 0)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .themePanel()
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            ([title, since, defenses > 0 ? competitionDefensesText(defenses) : nil].compactMap { $0 }
                + tape.map { "\($0.label): You \($0.you), \(name) \($0.them)" })
                .joined(separator: ", ")
        )
        .accessibilityIdentifier("competition.person.belt")
    }

    private func taleOfTheTape(
        _ rows: [(label: String, you: String, them: String)],
        name: String,
        latest: LocalCompetitionPresentation
    ) -> some View {
        let isStacked = dynamicTypeSize.isAccessibilitySize
        return VStack(spacing: 7) {
            Rectangle()
                .fill(Theme.hairline)
                .frame(height: 1)
                .padding(.bottom, 5)
            if !isStacked {
                HStack {
                    PersonAvatar(name: latest.ownerDisplayName, size: 44, isYou: true)
                    Spacer(minLength: 8)
                    PersonAvatar(name: name, photo: latest.opponentProfileID, size: 44)
                }
            }
            if !isStacked {
                tapeRow(you: "YOU", label: "TALE OF THE TAPE", them: name.uppercased(), valueFont: .themeLabel)
            }
            ForEach(rows, id: \.label) { row in
                if isStacked {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.label.uppercased())
                            .themeLabel(tracking: 1.1)
                            .foregroundStyle(Theme.secondary)
                        Text("You \(row.you)")
                            .foregroundStyle(Theme.you)
                        Text("\(name) \(row.them)")
                            .foregroundStyle(Theme.ink)
                    }
                    .font(.subheadline.bold())
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    tapeRow(
                        you: row.you,
                        label: row.label.uppercased(),
                        them: row.them,
                        valueFont: .system(size: tapeValueSize, weight: .heavy).width(.condensed).monospacedDigit()
                    )
                }
            }
        }
    }

    private func tapeRow(you: String, label: String, them: String, valueFont: Font) -> some View {
        CompetitionTapeRow(you: you, label: label, them: them, valueFont: valueFont)
    }

    private func sinceText(
        _ current: CompetitionBeltReign,
        weeks: [LocalCompetitionPresentation]
    ) -> String? {
        competitionBeltSinceText(current, weeks: weeks, now: publication.evaluatedAt, locale: locale, timeZone: timeZone)
    }

    private func weeksSection(
        _ record: CompetitionOpponentRecord,
        belt: CompetitionBelt,
        weeks: [LocalCompetitionPresentation],
        shown: Int?
    ) -> some View {
        let listed = showsAllWeeks ? weeks : Array(weeks.prefix(shown ?? weeks.count))
        return VStack(alignment: .leading, spacing: 10) {
            SectionLabel("WEEKS")
                .padding(.horizontal, 4)

            VStack(spacing: 0) {
                ForEach(Array(listed.enumerated()), id: \.element.id) { index, competition in
                    if index > 0 {
                        CompetitionRowDivider()
                    }
                    let took = tookText(belt.events[competition.id], name: record.opponentDisplayName)
                    NavigationLink(
                        value: CompetitionHomeRoute.competition(competition.id)
                    ) {
                        CompetitionSharingRow(
                            competition: competition,
                            source: publication.source,
                            showsName: false,
                            beltHolder: took?.holder
                        )
                        .contentShape(Rectangle())
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(
                            [
                                sharingAccessibilitySummary(
                                    competition,
                                    source: publication.source,
                                    locale: locale,
                                    timeZone: timeZone,
                                    includesName: false
                                ),
                                took?.title,
                            ]
                            .compactMap { $0 }
                            .joined(separator: ". ")
                        )
                        .accessibilityHint("Opens this match")
                    }
                    .buttonStyle(CompetitionRowButtonStyle())
                    .accessibilityIdentifier(competitionSharingIdentifier(competition))
                    .transition(Motion.appear)
                }
                if listed.count < weeks.count {
                    CompetitionRowDivider()
                    Button {
                        showsAllWeeks = true
                    } label: {
                        HStack {
                            Text("All \(weeks.count) weeks")
                                .font(.headline)
                                .foregroundStyle(Theme.ink)
                            Spacer(minLength: 8)
                            Image(systemName: "chevron.down")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(Theme.tertiary)
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(CompetitionRowButtonStyle())
                    .accessibilityHint("Shows every week")
                    .accessibilityIdentifier("competition.person.allWeeks")
                }
            }
            .themePanel()
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .moving(Motion.settle, value: showsAllWeeks)
        }
    }

    private func tookText(
        _ event: CompetitionBeltEvent?,
        name: String
    ) -> (holder: CompetitionBeltHolder, title: String)? {
        guard let event,
              case .took = event,
              let text = competitionBeltResultText(event, opponentName: name)
        else { return nil }
        return (text.holder, text.title)
    }
}

struct CompetitionPersonPlace: Equatable, Sendable {
    var depth = 0
    var showsRecords = false
    var showsProfile = false
    var showsWeeks = true
    var showsOwnProfile = false
    var showsOwnBadges = false
    var showsOwnRecords = false
}

enum CompetitionHomeRoute: Hashable {
    case history
    case friends
    case person(String)
    case profile(String)
    case ownProfile
    case ownBadges
    case ownRecords
    case records(String)
    case competition(CompetitionID, dayOrdinal: Int? = nil)

    static func stack(
        path: Binding<[CompetitionID]>,
        showsHistory: Binding<Bool>,
        person: Binding<String?>,
        personPlace: Binding<CompetitionPersonPlace> = .constant(CompetitionPersonPlace()),
        showsFriends: Binding<Bool> = .constant(false),
        dayOrdinals: Binding<[CompetitionID: Int]> = .constant([:])
    ) -> Binding<[CompetitionHomeRoute]> {
        Binding(
            get: {
                var routes = path.wrappedValue.map {
                    CompetitionHomeRoute.competition($0, dayOrdinal: dayOrdinals.wrappedValue[$0])
                }
                let place = personPlace.wrappedValue
                var people: [CompetitionHomeRoute] = place.showsOwnProfile ? [.ownProfile] : []
                if place.showsOwnProfile, place.showsOwnBadges { people.append(.ownBadges) }
                if place.showsOwnProfile, place.showsOwnRecords { people.append(.ownRecords) }
                if let identity = person.wrappedValue {
                    if place.showsProfile { people.append(.profile(identity)) }
                    if place.showsWeeks { people.append(.person(identity)) }
                    if place.showsRecords { people.append(.records(identity)) }
                }
                routes.insert(contentsOf: people, at: min(place.depth, routes.count))
                var bottom: [CompetitionHomeRoute] = []
                if showsFriends.wrappedValue { bottom.append(.friends) }
                if showsHistory.wrappedValue { bottom.append(.history) }
                return bottom + routes
            },
            set: { newRoutes in
                var routes = newRoutes
                if let repeated = routes.indices.first(where: {
                    routes[$0].isPersonPage && routes[($0 + 1)...].contains(routes[$0])
                }) {
                    routes = Array(routes[...repeated])
                }
                if let first = routes.firstIndex(where: \.isPersonPage),
                   let match = routes[first...].firstIndex(where: \.isCompetition),
                   routes[match...].contains(where: \.isPersonPage) {
                    if routes[first] == .ownProfile {
                        let own: [CompetitionHomeRoute] = [.ownProfile, .ownBadges, .ownRecords]
                        routes.removeAll { own.contains($0) }
                    } else {
                        routes = Array(routes[...first])
                    }
                }
                let personIndex = routes.firstIndex(where: \.isPersonPage)
                let identity = routes.lazy.compactMap(\.personIdentity).first
                showsHistory.wrappedValue = routes.first == .history
                showsFriends.wrappedValue = routes.first == .friends
                person.wrappedValue = identity
                personPlace.wrappedValue = CompetitionPersonPlace(
                    depth: personIndex.map { routes[..<$0].filter(\.isCompetition).count } ?? 0,
                    showsRecords: personIndex != nil && routes.contains {
                        if case .records = $0 { return true }
                        return false
                    },
                    showsProfile: routes.contains {
                        if case .profile = $0 { return true }
                        return false
                    },
                    showsWeeks: identity == nil || routes.contains {
                        if case .person = $0 { return true }
                        return false
                    },
                    showsOwnProfile: routes.contains(.ownProfile),
                    showsOwnBadges: routes.contains(.ownBadges),
                    showsOwnRecords: routes.contains(.ownRecords)
                )
                var ordinals: [CompetitionID: Int] = [:]
                var ids: [CompetitionID] = []
                for route in routes {
                    guard case let .competition(id, dayOrdinal) = route else { continue }
                    ids.append(id)
                    if let dayOrdinal { ordinals[id] = dayOrdinal }
                }
                dayOrdinals.wrappedValue = ordinals
                path.wrappedValue = ids
            }
        )
    }

    static func challengeSheetStack(
        routes: Binding<[CompetitionHomeRoute]>,
        isPresented: Binding<Bool>,
        closeFriends: @escaping () -> Void,
        openCompetition: @escaping (CompetitionID) -> Void
    ) -> Binding<[CompetitionHomeRoute]> {
        Binding(
            get: { routes.wrappedValue },
            set: { newRoutes in
                if let matchID = newRoutes.lazy.compactMap({
                    if case let .competition(id, _) = $0 { return id }
                    return nil
                }).first {
                    let hadFriends = routes.wrappedValue.contains(.friends)
                    routes.wrappedValue = []
                    isPresented.wrappedValue = false
                    if hadFriends { closeFriends() }
                    openCompetition(matchID)
                    return
                }
                var updated = newRoutes
                if let repeated = updated.indices.first(where: {
                    updated[$0].isPersonPage && updated[($0 + 1)...].contains(updated[$0])
                }) {
                    updated = Array(updated[...repeated])
                }
                let hadFriends = routes.wrappedValue.contains(.friends)
                let hasFriends = updated.contains(.friends)
                routes.wrappedValue = updated
                if hadFriends, !hasFriends { closeFriends() }
            }
        )
    }

    static func opening(_ route: Self, on routes: [Self]) -> [Self] {
        if !routes.contains(route), let first = routes.firstIndex(where: \.isPersonPage) {
            return Array(routes[..<first]) + [route]
        }
        return routes + [route]
    }

    private var isPersonPage: Bool {
        self == .ownProfile || personIdentity != nil
    }

    private var personIdentity: String? {
        switch self {
        case let .person(identity), let .profile(identity): identity
        default: nil
        }
    }

    private var isCompetition: Bool {
        if case .competition = self { return true }
        return false
    }
}

func competitionBeltTitle(_ belt: CompetitionBelt, name: String) -> String {
    if belt.isRetired { return "The belt is retired" }
    guard let holder = belt.holder else { return "No one holds the belt yet" }
    return competitionBeltStandingText(holder, opponentName: name)
}

func competitionBeltSinceText(
    _ current: CompetitionBeltReign,
    weeks: [LocalCompetitionPresentation],
    now: Date,
    locale: Locale,
    timeZone: TimeZone
) -> String? {
    guard let schedule = weeks.first(where: { $0.id == current.startID })?
        .acceptedConfiguration?.schedule,
        let lastDay = try? schedule.calendar.sevenDayWindow(startingOn: schedule.startDay).last
    else { return nil }
    let day = competitionDayText(lastDay, weekday: false, now: now, locale: locale, timeZone: timeZone)
    return "Since \(day) · \(competitionWeeksText(current.weeks))"
}

struct CompetitionChallengeButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.headline)
                .foregroundStyle(Theme.ink)
                .frame(width: 34, height: 34)
                .background(Theme.control, in: Circle())
        }
        .accessibilityLabel("Challenge Someone")
        .accessibilityIdentifier("competition.create.open")
    }
}

struct CompetitionRowDivider: View {
    var inset: CGFloat = 70

    var body: some View {
        Rectangle()
            .fill(Theme.hairline)
            .frame(height: 1)
            .padding(.leading, inset)
    }
}

private struct OpenSlotMark: View {
    var body: some View {
        ZStack {
            SlotPolygon([(17.4, 8), (57.4, 8), (53.8, 26), (13.8, 26)])
                .fill(Theme.move)
            SlotPolygon([(22.8, 31), (52.8, 31), (49.2, 49), (19.2, 49)])
                .fill(Theme.exercise)
            SlotPolygon([(12.2, 54), (48.2, 54), (44.6, 72), (8.6, 72)])
                .fill(Theme.stand)
            SlotPolygon([(63.4, 8), (91.4, 8), (78.6, 72), (50.6, 72)])
                .stroke(
                    Theme.tertiary,
                    style: StrokeStyle(lineWidth: 2, dash: [5, 4])
                )
        }
        .aspectRatio(1.25, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

private struct SlotPolygon: Shape {
    let points: [CGPoint]

    init(_ points: [(CGFloat, CGFloat)]) {
        self.points = points.map { CGPoint(x: $0.0, y: $0.1) }
    }

    func path(in rect: CGRect) -> Path {
        Path { path in
            path.addLines(points.map {
                CGPoint(
                    x: rect.minX + $0.x / 100 * rect.width,
                    y: rect.minY + $0.y / 80 * rect.height
                )
            })
            path.closeSubpath()
        }
    }
}

private func sharingOutcome(
    _ lifecycle: LocalCompetitionLifecyclePresentation
) -> CompetitionOutcome? {
    switch lifecycle {
    case let .completed(outcome, _, _), let .archived(outcome, _, _, _):
        outcome
    default:
        nil
    }
}

private func sharingFractionDigits(_ competition: LocalCompetitionPresentation) -> Int {
    sharingOutcome(competition.lifecycle) == nil
        ? 0
        : competitionFinalFractionDigits(
            userPoints: competition.userPoints,
            opponentPoints: competition.opponentPoints
        )
}

private func sharingAccessibilitySummary(
    _ competition: LocalCompetitionPresentation,
    source: CompetitionPublicationSource,
    locale: Locale = .current,
    timeZone: TimeZone = .current,
    includesName: Bool = true
) -> String {
    var parts = (includesName ? [competition.opponentDisplayName] : []) + [
        competitionHomeStatusLine(competition, locale: locale, timeZone: timeZone),
    ]
    if let disclosure = competitionFixtureDisclosure(
        source: source,
        opponentDisplayName: competition.opponentDisplayName
    ) {
        parts.append(disclosure)
    }
    if competitionShouldShowScores(competition.lifecycle) {
        let digits = sharingFractionDigits(competition)
        parts.append(
            "You \(competitionPointsAccessibilityText(competition.userPoints, fractionDigits: digits, locale: locale))"
        )
        parts.append(
            "\(competition.opponentDisplayName) \(competitionPointsAccessibilityText(competition.opponentPoints, fractionDigits: digits, locale: locale))"
        )
    }
    return parts.joined(separator: ". ")
}

struct CompetitionPressButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
            .opacity(configuration.isPressed && reduceMotion ? 0.8 : 1)
            .animation(Motion.press, value: configuration.isPressed)
    }
}

struct CompetitionRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Theme.control : .clear)
    }
}

enum CompetitionStatusStyle: Equatable, Sendable {
    case row
    case card
    case notification
}

struct CompetitionStatusText: Equatable, Sendable {
    let title: String
    let timing: String?

    var line: String {
        [title, timing].compactMap { $0 }.joined(separator: " · ")
    }
}

func competitionStatusText(
    _ competition: LocalCompetitionPresentation,
    style: CompetitionStatusStyle,
    locale: Locale = .current,
    timeZone: TimeZone = .current
) -> CompetitionStatusText {
    let base = competitionStatusText(
        competition.lifecycle,
        schedule: competition.acceptedConfiguration?.schedule,
        opponentDisplayName: competition.opponentDisplayName,
        style: style,
        now: competition.evaluatedAt,
        locale: locale,
        timeZone: timeZone
    )
    let title = competition.isPractice && style != .notification
        ? "Practice · \(base.title)" : base.title
    guard case .tallying = competition.lifecycle,
          style != .notification,
          let deadline = competition.tally?.bestAvailableDeadline,
          competition.evaluatedAt < deadline
    else {
        return CompetitionStatusText(title: title, timing: base.timing)
    }
    return CompetitionStatusText(
        title: title,
        timing: "By \(competitionDeadlineText(deadline, now: competition.evaluatedAt, locale: locale, timeZone: timeZone))"
    )
}

func competitionStatusText(
    _ lifecycle: LocalCompetitionLifecyclePresentation,
    schedule: CompetitionSchedule?,
    opponentDisplayName name: String,
    style: CompetitionStatusStyle,
    now: Date = Date.now,
    locale: Locale = .current,
    timeZone: TimeZone = .current
) -> CompetitionStatusText {
    let days = schedule.flatMap {
        try? $0.calendar.sevenDayWindow(startingOn: $0.startDay)
    }
    let bounds = schedule.flatMap(competitionScheduleBoundaries)
    func zone(_ instant: Date?) -> String {
        guard let instant,
              let identifier = schedule?.calendar.timeZoneIdentifier,
              let calendarZone = TimeZone(identifier: identifier),
              calendarZone.secondsFromGMT(for: instant)
                != timeZone.secondsFromGMT(for: instant)
        else {
            return ""
        }
        return " " + (calendarZone.abbreviation(for: instant) ?? identifier)
    }
    var starts: String? {
        days?.first.map {
            "Starts \(competitionDayText($0, now: now, locale: locale, timeZone: timeZone))"
                + zone(bounds?.start)
        }
    }
    var week: String? {
        guard let first = days?.first, let last = days?.last else { return nil }
        return competitionWeekText(first, last, now: now, locale: locale, timeZone: timeZone)
    }
    let status: CompetitionStatusText = switch lifecycle {
    case let .pending(direction, _, _):
        switch (direction, style) {
        case (.incoming, .notification):
            CompetitionStatusText(title: "\(name) challenged you", timing: nil)
        case (.incoming, _):
            CompetitionStatusText(title: "Challenge received", timing: nil)
        case (.outgoing, .notification):
            CompetitionStatusText(title: "Challenge to \(name)", timing: nil)
        case (.outgoing, _):
            CompetitionStatusText(title: "Challenge sent", timing: nil)
        }
    case .declined:
        CompetitionStatusText(
            title: style == .notification ? "Challenge declined" : "Declined",
            timing: nil
        )
    case .expired:
        CompetitionStatusText(
            title: style == .notification ? "Challenge expired" : "Expired",
            timing: nil
        )
    case .cancelled:
        CompetitionStatusText(
            title: style == .card ? "Cancelled" : "Match cancelled",
            timing: nil
        )
    case .scheduled:
        switch (style, starts) {
        case let (.card, starts?):
            CompetitionStatusText(title: "Scheduled", timing: starts)
        case let (_, starts?):
            CompetitionStatusText(title: starts, timing: nil)
        case (_, nil):
            CompetitionStatusText(title: "Scheduled", timing: nil)
        }
    case let .active(dayOrdinal):
        CompetitionStatusText(
            title: "Day \(dayOrdinal) of 7",
            timing: days?.last.map {
                "Ends \(weekdayText($0, locale: locale)) night" + zone(bounds?.end)
            }
        )
    case .endsToday:
        CompetitionStatusText(
            title: "Last day",
            timing: days == nil ? nil : "Ends at midnight" + zone(bounds?.end)
        )
    case .tallying:
        CompetitionStatusText(title: "Final score pending", timing: nil)
    case let .completed(outcome, _, _), let .archived(outcome, _, _, _):
        switch (outcome, style) {
        case (_, .notification):
            CompetitionStatusText(
                title: competitionResultTitle(outcome: outcome, opponentDisplayName: name),
                timing: nil
            )
        case (.win, _):
            CompetitionStatusText(title: "You won", timing: week)
        case (.loss, _):
            CompetitionStatusText(title: "\(name) won", timing: week)
        case (.tie, _):
            CompetitionStatusText(title: "Tied", timing: week)
        }
    }
    return style == .notification
        ? CompetitionStatusText(title: status.title, timing: nil)
        : status
}

func competitionShouldShowScores(
    _ lifecycle: LocalCompetitionLifecyclePresentation
) -> Bool {
    switch lifecycle {
    case .pending, .scheduled, .declined, .expired, .cancelled:
        return false
    case .active, .endsToday, .tallying, .completed, .archived:
        return true
    }
}

func competitionSharingIdentifier(
    _ competition: LocalCompetitionPresentation
) -> String {
    "competition.sharing.\(competitionSharingState(competition.lifecycle)).\(competition.id.rawValue.uuidString.lowercased())"
}

func competitionSharingState(_ lifecycle: LocalCompetitionLifecyclePresentation) -> String {
    switch lifecycle {
    case .pending: "pending"
    case .declined: "declined"
    case .expired: "expired"
    case .cancelled: "cancelled"
    case .scheduled: "scheduled"
    case .active: "active"
    case .endsToday: "ends-today"
    case .tallying: "tallying"
    case .completed: "completed"
    case .archived: "archived"
    }
}

func competitionIssueSummary(
    _ issues: [LocalCompetitionClientIssue],
    attributedIDs: Set<CompetitionID>
) -> String? {
    let remaining = issues.filter { issue in
        switch issue {
        case let .competitionFailures(ids), let .activityFailures(ids):
            !ids.allSatisfy(attributedIDs.contains)
        case let .commandRejected(id):
            !attributedIDs.contains(id)
        default:
            true
        }
    }
    guard !remaining.isEmpty else { return nil }
    if remaining.contains(.storageUnavailable) {
        return "Match storage on this iPhone is unavailable."
    }
    if remaining.contains(.authorizationUnavailable) {
        return "HealthComp can’t read Health. Check Account → Health."
    }
    if remaining.contains(.remoteFailure) {
        return "Matches could not be refreshed."
    }
    if remaining.contains(.remoteUnavailable) {
        return "Offline. Scores update when you reconnect."
    }
    if remaining.contains(where: {
        if case .competitionFailures = $0 { return true }
        return false
    }) {
        return "Some matches could not be refreshed."
    }
    if remaining.contains(where: {
        if case .activityFailures = $0 { return true }
        return false
    }) {
        return "Matches loaded, but Activity could not be refreshed."
    }
    return "The last match action could not be completed."
}

struct CompetitionHomeLayout: Equatable {
    let hero: LocalCompetitionPresentation?
    let needsYou: [LocalCompetitionPresentation]
    let live: [LocalCompetitionPresentation]
    let upNext: [LocalCompetitionPresentation]
    let recentResults: [LocalCompetitionPresentation]

    var isEmpty: Bool {
        hero == nil && needsYou.isEmpty && live.isEmpty && upNext.isEmpty
            && recentResults.isEmpty
    }

    var allItems: [LocalCompetitionPresentation] {
        [hero].compactMap { $0 } + needsYou + live + upNext + recentResults
    }

    var shape: [[String]] {
        [[hero].compactMap { $0 }, needsYou, live, upNext, recentResults]
            .map { $0.map(competitionSharingIdentifier) }
    }
}

struct CompetitionDismissedChallenges: RawRepresentable, Equatable {
    static let storageKey = "healthcomp.dismissedChallenges"

    var ids: Set<CompetitionID>

    init(ids: Set<CompetitionID> = []) {
        self.ids = ids
    }

    init?(rawValue: String) {
        guard let data = rawValue.data(using: .utf8),
              let rawIDs = try? JSONDecoder().decode([String].self, from: data)
        else { return nil }
        var decoded = Set<CompetitionID>()
        for rawID in rawIDs {
            guard let uuid = UUID(uuidString: rawID) else { return nil }
            decoded.insert(CompetitionID(uuid))
        }
        self.ids = decoded
    }

    var rawValue: String {
        let sorted = ids.map { $0.rawValue.uuidString.lowercased() }.sorted()
        guard let data = try? JSONEncoder().encode(sorted) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }

    func contains(_ id: CompetitionID) -> Bool {
        ids.contains(id)
    }

    func dismissing(_ id: CompetitionID) -> Self {
        var next = self
        next.ids.insert(id)
        return next
    }
}

func competitionHomeLayout(
    _ dashboard: LocalCompetitionDashboard,
    now: Date,
    dismissedChallengeIDs: Set<CompetitionID> = []
) -> CompetitionHomeLayout {
    var needsYou: [LocalCompetitionPresentation] = []
    var live: [LocalCompetitionPresentation] = []
    var scheduled: [LocalCompetitionPresentation] = []
    var outgoing: [LocalCompetitionPresentation] = []
    var closed: [LocalCompetitionPresentation] = []
    var results: [LocalCompetitionPresentation] = []
    for competition in dashboard.competitions {
        switch competition.lifecycle {
        case .pending(.incoming, _, _):
            needsYou.append(competition)
        case .pending(.outgoing, _, _):
            outgoing.append(competition)
        case .active, .endsToday, .tallying:
            live.append(competition)
        case .scheduled:
            scheduled.append(competition)
        case .declined, .expired, .cancelled:
            if competitionIsClosedOutgoing(competition.lifecycle),
               !dismissedChallengeIDs.contains(competition.id) {
                closed.append(competition)
            }
        case .completed:
            if now < competitionResultLeavesHome(competition)?.at ?? .distantFuture {
                results.append(competition)
            }
        case .archived:
            break
        }
    }

    func bounds(_ competition: LocalCompetitionPresentation) -> (start: Date, end: Date)? {
        competition.acceptedConfiguration.flatMap {
            competitionScheduleBoundaries($0.schedule)
        }
    }
    func pending(_ competition: LocalCompetitionPresentation) -> (expiresAt: Date, createdAt: Date) {
        guard case let .pending(_, createdAt, expiresAt) = competition.lifecycle else {
            return (.distantFuture, .distantFuture)
        }
        return (expiresAt ?? .distantFuture, createdAt)
    }
    func closedAt(_ competition: LocalCompetitionPresentation) -> Date {
        switch competition.lifecycle {
        case let .declined(at, _), let .expired(at, _), let .cancelled(at): at
        default: .distantPast
        }
    }
    let byName = { (lhs: LocalCompetitionPresentation, rhs: LocalCompetitionPresentation) in
        lhs.opponentDisplayName.localizedStandardCompare(rhs.opponentDisplayName)
    }

    live = competitionHomeSorted(live, [
        competitionAscending { bounds($0)?.end ?? .distantFuture },
        competitionAscending { bounds($0)?.start ?? .distantFuture },
        byName,
    ])
    scheduled = competitionHomeSorted(scheduled, [
        competitionAscending { bounds($0)?.start ?? .distantFuture },
        byName,
    ])
    needsYou = competitionHomeSorted(needsYou, [
        competitionAscending { pending($0).expiresAt },
        competitionAscending { pending($0).createdAt },
    ])
    outgoing = competitionHomeSorted(outgoing, [
        competitionAscending { pending($0).expiresAt },
        competitionAscending { pending($0).createdAt },
    ])
    closed = competitionHomeSorted(closed, [
        competitionAscending { -closedAt($0).timeIntervalSinceReferenceDate },
    ])
    results = competitionHomeSorted(results, [
        competitionAscending {
            -($0.terminalResult?.completedAt ?? .distantPast).timeIntervalSinceReferenceDate
        },
    ])

    var hero: LocalCompetitionPresentation?
    if live.contains(where: { !$0.isPractice }) {
        if live.count == 1 { hero = live.removeFirst() }
    } else if let index = scheduled.firstIndex(where: { !$0.isPractice }) {
        hero = scheduled.remove(at: index)
    } else if live.count == 1 {
        hero = live.removeFirst()
    } else if live.isEmpty, !scheduled.isEmpty {
        hero = scheduled.removeFirst()
    }
    return CompetitionHomeLayout(
        hero: hero,
        needsYou: needsYou,
        live: live,
        upNext: scheduled + outgoing + closed,
        recentResults: results
    )
}

private func competitionHomeSorted(
    _ competitions: [LocalCompetitionPresentation],
    _ comparisons: [(LocalCompetitionPresentation, LocalCompetitionPresentation) -> ComparisonResult]
) -> [LocalCompetitionPresentation] {
    competitions.sorted { lhs, rhs in
        for compare in comparisons {
            let result = compare(lhs, rhs)
            if result != .orderedSame { return result == .orderedAscending }
        }
        return lhs.id.rawValue.uuidString < rhs.id.rawValue.uuidString
    }
}

private func competitionAscending<Key: Comparable>(
    _ key: @escaping (LocalCompetitionPresentation) -> Key
) -> (LocalCompetitionPresentation, LocalCompetitionPresentation) -> ComparisonResult {
    { lhs, rhs in
        let (left, right) = (key(lhs), key(rhs))
        return left < right ? .orderedAscending : left > right ? .orderedDescending : .orderedSame
    }
}

func competitionIsClosedOutgoing(_ lifecycle: LocalCompetitionLifecyclePresentation) -> Bool {
    switch lifecycle {
    case .declined(_, .outgoing), .expired(_, .outgoing), .cancelled: true
    default: false
    }
}

func competitionResultLeavesHome(
    _ competition: LocalCompetitionPresentation
) -> (day: CompetitionDay, at: Date)? {
    guard let schedule = competition.acceptedConfiguration?.schedule,
          let completedAt = competition.terminalResult?.completedAt
    else { return nil }
    return competitionResultLeavesHome(schedule: schedule, completedAt: completedAt)
}

func competitionResultLeavesHome(
    schedule: CompetitionSchedule,
    completedAt: Date
) -> (day: CompetitionDay, at: Date)? {
    let calendar = schedule.calendar
    func advanced(_ day: CompetitionDay, by count: Int) throws -> CompetitionDay {
        try (0..<count).reduce(day) { day, _ in try calendar.day(after: day) }
    }
    guard let last = try? calendar.sevenDayWindow(startingOn: schedule.startDay).last,
          let afterWeek = try? advanced(last, by: 4),
          let afterTally = try? advanced(calendar.day(containing: completedAt), by: 2),
          let afterWeekStart = try? calendar.startOfDay(afterWeek),
          let afterTallyStart = try? calendar.startOfDay(afterTally)
    else { return nil }
    return afterWeekStart >= afterTallyStart
        ? (afterWeek, afterWeekStart)
        : (afterTally, afterTallyStart)
}

func competitionHomeStatusLine(
    _ competition: LocalCompetitionPresentation,
    locale: Locale = .current,
    timeZone: TimeZone = .current
) -> String {
    let line = competitionStatusText(
        competition, style: .row, locale: locale, timeZone: timeZone
    ).line
    guard case let .pending(_, _, expiresAt?) = competition.lifecycle,
          expiresAt > competition.evaluatedAt
    else { return line }
    let moment = competitionMomentText(
        expiresAt, now: competition.evaluatedAt, locale: locale, timeZone: timeZone
    )
    return "\(line) · Expires \(moment)"
}

func competitionClosedChallengeText(
    _ competition: LocalCompetitionPresentation,
    locale: Locale = .current,
    timeZone: TimeZone = .current
) -> (title: String, line: String)? {
    let name = competition.opponentDisplayName
    func moment(_ at: Date) -> String {
        competitionMomentText(at, now: competition.evaluatedAt, locale: locale, timeZone: timeZone)
    }
    switch competition.lifecycle {
    case let .expired(at, .outgoing):
        return ("\(name) didn’t accept", "Your challenge expired \(moment(at))")
    case let .declined(at, .outgoing):
        return ("\(name) declined", "Declined \(moment(at))")
    case .declined(_, .incoming):
        return ("Challenge declined", "You declined \(name)’s challenge")
    case let .expired(at, .incoming):
        return ("Challenge expired", "\(name)’s challenge expired \(moment(at))")
    case let .cancelled(at):
        return ("Match cancelled", "\(name) cancelled it \(moment(at))")
    default:
        return nil
    }
}

struct CompetitionOpponentRecord: Equatable {
    let opponentIdentity: String
    let opponentDisplayName: String
    let wins: Int
    let losses: Int
    let ties: Int
    let latest: LocalCompetitionPresentation
    var belt: CompetitionBelt = .vacant

    var text: String {
        ([wins, losses] + (ties > 0 ? [ties] : [])).map(String.init).joined(separator: "–")
    }

    var accessibilityText: String {
        func count(_ value: Int, _ one: String, _ many: String) -> String {
            "\(value) \(value == 1 ? one : many)"
        }
        var parts = [
            opponentDisplayName,
            count(wins, "win", "wins"),
            count(losses, "loss", "losses"),
        ]
        if ties > 0 { parts.append(count(ties, "tie", "ties")) }
        return parts.joined(separator: ", ")
    }
}

func competitionHistoryWeeks(
    _ competitions: [LocalCompetitionPresentation]
) -> [LocalCompetitionPresentation] {
    let weeks = competitions.filter { $0.terminalResult != nil && !$0.isPractice }
    let ends: [CompetitionID: Date] = Dictionary(weeks.map { week -> (CompetitionID, Date) in
        (week.id, week.acceptedConfiguration.flatMap { competitionScheduleBoundaries($0.schedule)?.end }
            ?? week.terminalResult?.completedAt ?? .distantPast)
    }, uniquingKeysWith: { first, _ in first })
    return competitionHomeSorted(weeks, [
        competitionAscending {
            -(ends[$0.id] ?? .distantPast).timeIntervalSinceReferenceDate
        },
        competitionAscending {
            -($0.terminalResult?.completedAt ?? .distantPast).timeIntervalSinceReferenceDate
        },
    ])
}

func competitionOpponentRecords(
    _ competitions: [LocalCompetitionPresentation]
) -> [CompetitionOpponentRecord] {
    var order: [String] = []
    var weeksByIdentity: [String: [LocalCompetitionPresentation]] = [:]
    for week in competitionHistoryWeeks(competitions) {
        if weeksByIdentity[week.opponentIdentity] == nil { order.append(week.opponentIdentity) }
        weeksByIdentity[week.opponentIdentity, default: []].append(week)
    }
    return order.compactMap { identity in
        guard let weeks = weeksByIdentity[identity], let latest = weeks.first else { return nil }
        let outcomes = weeks.compactMap(\.terminalResult?.outcome)
        return CompetitionOpponentRecord(
            opponentIdentity: identity,
            opponentDisplayName: latest.opponentDisplayName,
            wins: outcomes.filter { $0 == .win }.count,
            losses: outcomes.filter { $0 == .loss }.count,
            ties: outcomes.filter { $0 == .tie }.count,
            latest: latest,
            belt: competitionBelt(
                of: weeks,
                isRetired: latest.opponentDisplayName == competitionFormerCompetitorName
            )
        )
    }
}

func competitionHistorySummaryText(_ records: [CompetitionOpponentRecord]) -> String {
    let shown = records.prefix(2).map { "\($0.opponentDisplayName) \($0.text)" }
    let more = records.count > 2 ? ["\(records.count - 2) more"] : []
    return (shown + more).joined(separator: " · ")
}

func competitionHistorySummaryAccessibilityText(_ records: [CompetitionOpponentRecord]) -> String {
    let more = records.count - 2
    let shown = records.prefix(2).map(\.accessibilityText)
    let extra = more > 0 ? ["\(more) more \(more == 1 ? "person" : "people")"] : []
    return (shown + extra).joined(separator: ". ")
}

let competitionFormerCompetitorName = "Former competitor"

enum CompetitionBeltHolder: Equatable, Sendable { case you, them }

enum CompetitionBeltEvent: Equatable, Sendable {
    case vacant
    case took(by: CompetitionBeltHolder, fromWeeks: Int?, fromDefenses: Int = 0)
    case kept(by: CompetitionBeltHolder, weeks: Int)
    case defended(by: CompetitionBeltHolder, weeks: Int, defenses: Int)
}

struct CompetitionBeltReign: Equatable, Sendable {
    let holder: CompetitionBeltHolder
    let weeks: Int
    let startID: CompetitionID
    var defenses = 0
}

struct CompetitionTitleStats: Equatable, Sendable {
    var wins = 0
    var losses = 0
    var ties = 0
    var reigns = 0
    var defenses = 0
    var mostDefenses = 0
    var longestReign = 0
    var biggestWin: Double?
}

struct CompetitionBelt: Equatable, Sendable {
    let current: CompetitionBeltReign?
    let longest: CompetitionBeltReign?
    let mostDefenses: CompetitionBeltReign?
    let changes: Int
    let events: [CompetitionID: CompetitionBeltEvent]
    let you: CompetitionTitleStats
    let them: CompetitionTitleStats
    let isRetired: Bool
    var holder: CompetitionBeltHolder? { isRetired ? nil : current?.holder }
    static let vacant = Self(
        current: nil,
        longest: nil,
        mostDefenses: nil,
        changes: 0,
        events: [:],
        you: CompetitionTitleStats(),
        them: CompetitionTitleStats(),
        isRetired: false
    )
}

func competitionBelt(
    _ weeks: [(id: CompetitionID, end: Date?, outcome: CompetitionOutcome, margin: Double)],
    isRetired: Bool = false
) -> CompetitionBelt {
    let ordered = weeks.sorted {
        ($0.end ?? .distantPast, $0.id.rawValue.uuidString)
            < ($1.end ?? .distantPast, $1.id.rawValue.uuidString)
    }
    var current: CompetitionBeltReign?
    var longest: CompetitionBeltReign?
    var mostDefenses: CompetitionBeltReign?
    var changes = 0
    var events: [CompetitionID: CompetitionBeltEvent] = [:]
    var you = CompetitionTitleStats()
    var them = CompetitionTitleStats()
    func stats(of holder: CompetitionBeltHolder, _ update: (inout CompetitionTitleStats) -> Void) {
        holder == .you ? update(&you) : update(&them)
    }
    for week in ordered {
        let winner: CompetitionBeltHolder? = switch week.outcome {
        case .win: .you
        case .loss: .them
        case .tie: nil
        }
        if let winner {
            stats(of: winner) {
                $0.wins += 1
                $0.biggestWin = max($0.biggestWin ?? 0, week.margin)
            }
            stats(of: winner == .you ? .them : .you) { $0.losses += 1 }
        } else {
            you.ties += 1
            them.ties += 1
        }
        if let reign = current, winner == nil || winner == reign.holder {
            let defenses = reign.defenses + (winner == nil ? 0 : 1)
            current = CompetitionBeltReign(
                holder: reign.holder,
                weeks: reign.weeks + 1,
                startID: reign.startID,
                defenses: defenses
            )
            if winner == nil {
                events[week.id] = .kept(by: reign.holder, weeks: reign.weeks + 1)
            } else {
                events[week.id] = .defended(by: reign.holder, weeks: reign.weeks + 1, defenses: defenses)
                stats(of: reign.holder) { $0.defenses += 1 }
            }
        } else if let winner {
            events[week.id] = .took(
                by: winner,
                fromWeeks: current?.weeks,
                fromDefenses: current?.defenses ?? 0
            )
            current = CompetitionBeltReign(holder: winner, weeks: 1, startID: week.id)
            changes += 1
            stats(of: winner) { $0.reigns += 1 }
        } else {
            events[week.id] = .vacant
        }
        guard let reign = current else { continue }
        if reign.weeks >= (longest?.weeks ?? 0) { longest = reign }
        if reign.defenses > 0, reign.defenses >= (mostDefenses?.defenses ?? 0) { mostDefenses = reign }
        stats(of: reign.holder) {
            $0.longestReign = max($0.longestReign, reign.weeks)
            $0.mostDefenses = max($0.mostDefenses, reign.defenses)
        }
    }
    return CompetitionBelt(
        current: current,
        longest: longest,
        mostDefenses: mostDefenses,
        changes: changes,
        events: events,
        you: you,
        them: them,
        isRetired: isRetired
    )
}

func competitionBelt(
    of weeks: [LocalCompetitionPresentation],
    isRetired: Bool = false
) -> CompetitionBelt {
    competitionBelt(
        weeks.compactMap { week in
            week.terminalResult.map {
                (
                    id: week.id,
                    end: week.acceptedConfiguration.flatMap {
                        competitionScheduleBoundaries($0.schedule)?.end
                    },
                    outcome: $0.outcome,
                    margin: abs($0.userPoints - $0.opponentPoints)
                )
            }
        },
        isRetired: isRetired
    )
}

func competitionBeltEvent(
    for competition: LocalCompetitionPresentation,
    in competitions: [LocalCompetitionPresentation]
) -> CompetitionBeltEvent? {
    guard !competitionBeltWaitsOnAnEarlierMatch(competition, in: competitions) else { return nil }
    return competitionOpponentRecords(competitions)
        .first { $0.opponentIdentity == competition.opponentIdentity }?
        .belt.events[competition.id]
}

func competitionBeltWaitsOnAnEarlierMatch(
    _ competition: LocalCompetitionPresentation,
    in competitions: [LocalCompetitionPresentation]
) -> Bool {
    func start(_ match: LocalCompetitionPresentation) -> Date? {
        match.acceptedConfiguration.flatMap { competitionScheduleBoundaries($0.schedule)?.start }
    }
    guard let mine = start(competition) else { return false }
    return competitions.contains { other in
        guard other.id != competition.id,
              other.opponentIdentity == competition.opponentIdentity,
              let theirs = start(other), theirs < mine
        else { return false }
        switch other.lifecycle {
        case .scheduled, .active, .endsToday, .tallying: return true
        default: return false
        }
    }
}

func competitionWeeksText(_ count: Int) -> String { count == 1 ? "1 week" : "\(count) weeks" }

func competitionDefensesText(_ count: Int) -> String { count == 1 ? "1 defense" : "\(count) defenses" }

func competitionReignText(weeks: Int, defenses: Int) -> String {
    let length = competitionWeeksText(weeks)
    return defenses > 0 ? "\(length) · \(competitionDefensesText(defenses))" : length
}

func competitionBeltStandingText(_ holder: CompetitionBeltHolder, opponentName: String) -> String {
    holder == .you ? "You hold the belt" : "\(opponentName) holds the belt"
}

func competitionBeltChipText(_ belt: CompetitionBelt, opponentName: String) -> String? {
    guard let holder = belt.holder else { return nil }
    let standing = competitionBeltStandingText(holder, opponentName: opponentName)
    let defenses = belt.current?.defenses ?? 0
    return defenses > 0 ? "\(standing) · \(competitionDefensesText(defenses))" : standing
}

func competitionTaleOfTheTape(
    _ belt: CompetitionBelt
) -> [(label: String, you: String, them: String)] {
    func row(_ label: String, _ value: (CompetitionTitleStats) -> String) -> (label: String, you: String, them: String) {
        (label, value(belt.you), value(belt.them))
    }
    return [
        row("Title reigns") { String($0.reigns) },
        row("Title defenses") { String($0.defenses) },
        row("Longest reign") { $0.longestReign > 0 ? competitionWeeksText($0.longestReign) : "–" },
        row("Biggest win") {
            $0.biggestWin.map {
                "+\(competitionPointsText($0, fractionDigits: $0.rounded() == 0 ? 2 : 0))"
            } ?? "–"
        },
    ]
}

func competitionTitleDefenseText(_ defenses: Int) -> String {
    "\(competitionOrdinalText(defenses)) title defense"
}

func competitionBeltResultText(
    _ event: CompetitionBeltEvent,
    opponentName: String
) -> (holder: CompetitionBeltHolder, title: String, detail: String?)? {
    func name(_ holder: CompetitionBeltHolder) -> String { holder == .you ? "You" : opponentName }
    switch event {
    case let .took(holder, fromWeeks, _):
        let previous: CompetitionBeltHolder = holder == .you ? .them : .you
        return (
            holder,
            "\(name(holder)) took the belt",
            fromWeeks.map { "\(name(previous)) held it for \(competitionWeeksText($0))." }
        )
    case let .defended(holder, weeks, defenses):
        let title = competitionTitleDefenseText(defenses)
        return (holder, holder == .you ? title : "\(opponentName)’s \(title)", "\(weeks) weeks in a row.")
    case let .kept(holder, weeks) where weeks >= 3:
        return (holder, "\(name(holder)) kept the belt", "\(weeks) weeks in a row.")
    case .kept, .vacant:
        return nil
    }
}

enum CompetitionRowIssue: Equatable, Sendable {
    case command
    case refresh
    case activity
}

func competitionRowIssue(
    _ id: CompetitionID,
    in issues: [LocalCompetitionClientIssue]
) -> CompetitionRowIssue? {
    if issues.contains(.commandRejected(id)) { return .command }
    if issues.contains(where: {
        if case let .competitionFailures(ids) = $0 { return ids.contains(id) }
        return false
    }) {
        return .refresh
    }
    if issues.contains(where: {
        if case let .activityFailures(ids) = $0 { return ids.contains(id) }
        return false
    }) {
        return .activity
    }
    return nil
}
