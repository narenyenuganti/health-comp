import CompetitionCore
import SwiftUI

/// Home: what is in play right now, grouped as Needs you, Live, Up next and
/// Recent results. Creating a challenge opens in a drawer, finished weeks
/// live in History, and notifications and privacy live in Account.
struct CompetitionSharingView: View {
    let publication: LocalCompetitionPublication
    let challengeStatus: CompetitionFeature.ChallengeSheetStatus
    let senderName: String?
    var ownChallengeLink: URL? = nil
    let dismissChallenge: () -> Void
    @Binding var recipientCode: String
    let recipient: CompetitionFeature.InviteRecipient?
    let recipientStatus: CompetitionFeature.InviteRecipientStatus
    let findRecipient: () -> Void
    let createInvite: () -> Void
    /// Set by the host's + button and by the empty state.
    @Binding var isChallengePresented: Bool
    let selectCompetition: (CompetitionID) -> Void
    let openHistory: () -> Void
    let reinvite: () -> Void
    let isReinviteInFlight: Bool
    let challengeAgain: (CompetitionID) -> Void
    let archive: (CompetitionID) -> Void
    let commandIDsInFlight: Set<CompetitionID>
    let retry: () async -> Void
    /// Real-match Home only: Practice Match on the first-time empty state.
    var practice: CompetitionPracticeStart? = nil
    /// The pace sheet, presented by the host above `.refreshable`, so a
    /// downward drag closes it instead of refreshing Home.
    var isPracticePresented: Binding<Bool> = .constant(false)

    // ponytail: in-memory, a dismissed row returns after relaunch within its 24 h; persist per profile if that annoys
    @State private var dismissedChallengeIDs: Set<CompetitionID> = []
    @AppStorage(CompetitionReactionsSeen.storageKey)
    private var reactionsSeen = CompetitionReactionsSeen()

    @Environment(\.locale) private var locale
    @Environment(\.timeZone) private var timeZone

    var body: some View {
        let layout = self.layout
        let records = self.records
        // A plain VStack keeps every card in the hierarchy, so scrolling to a
        // card works in both directions.
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if let summary = competitionIssueSummary(
                    publication.dashboard.issues,
                    attributedIDs: attributedIDs(layout)
                ) {
                    issueBanner(summary)
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
                    VStack(alignment: .leading, spacing: 12) {
                        competitionButton(hero, caption: homeCaption(beltStanding(belt, hero), hero)) {
                            CompetitionHeroCard(
                                competition: hero,
                                source: publication.source,
                                belt: belt,
                                reaction: unseen(hero)
                            )
                        }
                        .buttonStyle(CompetitionPressButtonStyle())
                        issueLine(hero)
                    }
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
                                            reaction: unseen(competition)
                                        )
                                    }
                                    .buttonStyle(CompetitionPressButtonStyle())
                                    issueLine(competition)
                                }
                                .padding(16)
                                .themePanel()
                            }
                        }
                    }
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
                                    dismiss: { dismissedChallengeIDs.insert(competition.id) }
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

                // With only a practice on Home, the way to a real match stays in view.
                if publication.source == .remoteParticipants,
                   !layout.allItems.isEmpty,
                   layout.allItems.allSatisfy(\.isPractice) {
                    Button("Challenge Someone") {
                        isChallengePresented = true
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .accessibilityIdentifier("competition.practice.challenge")
                }

                if layout.isEmpty {
                    emptyState
                }

                if !records.isEmpty {
                    historyButton
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(Theme.ground)
        .navigationTitle("Home")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // The bar shows only the mark and its buttons; the title stays
            // for VoiceOver and the navigation bar's identity.
            ToolbarItem(placement: .principal) {
                Color.clear
                    .frame(width: 1, height: 1)
                    .accessibilityHidden(true)
            }
        }
        .sheet(isPresented: $isChallengePresented, onDismiss: dismissChallenge) {
            CreateCompetitionView(
                status: challengeStatus,
                timeZoneIdentifier: publication.timeZoneIdentifier,
                evaluatedAt: publication.evaluatedAt,
                recipientCode: $recipientCode,
                recipient: recipient,
                recipientStatus: recipientStatus,
                senderName: senderName,
                ownChallengeLink: ownChallengeLink,
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
            dismissedChallengeIDs: dismissedChallengeIDs
        )
    }

    private var records: [CompetitionOpponentRecord] {
        competitionOpponentRecords(publication.dashboard.competitions)
    }

    /// Who holds the belt going in; nil while an earlier match with the same
    /// person could still move it.
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
        belt?.holder.map {
            competitionBeltStandingText($0, opponentName: competition.opponentDisplayName)
        }
    }

    private func unseen(_ competition: LocalCompetitionPresentation) -> CompetitionReaction? {
        competitionUnseenReaction(competition, seen: reactionsSeen)
    }

    /// VoiceOver only: the visible caption (or belt standing), then the
    /// unseen reaction.
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

    /// Matches drawn on Home carry their own problem line, so the banner
    /// leaves them out. A failed practice start shows on its sheet.
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
    }

    private func rowPanel<Row: View>(
        _ competitions: [LocalCompetitionPresentation],
        @ViewBuilder row: @escaping (LocalCompetitionPresentation) -> Row
    ) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(competitions.enumerated()), id: \.element.id) { index, competition in
                if index > 0 {
                    CompetitionRowDivider()
                }
                VStack(spacing: 0) {
                    row(competition)
                    issueLine(competition, inset: true)
                }
            }
        }
        .themePanel()
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
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
            // Nothing to archive: it's deleted when it leaves Home.
            rowButton(competition)
        } else {
            archivableResultRow(competition)
        }
    }

    @ViewBuilder
    private func archivableResultRow(_ competition: LocalCompetitionPresentation) -> some View {
        let caption = competitionResultLeavesHome(competition).map {
            "Moves to History \(weekdayText($0.day, locale: locale))"
        }
        CompetitionArchiveSwipeRow(
            id: competition.id,
            isInFlight: commandIDsInFlight.contains(competition.id),
            label: "Archive. \(competition.opponentDisplayName). \(competitionHomeStatusLine(competition, locale: locale, timeZone: timeZone))",
            archive: { archive(competition.id) }
        ) {
            competitionButton(competition, caption: homeCaption(caption, competition)) {
                CompetitionSharingRow(
                    competition: competition,
                    source: publication.source,
                    caption: caption,
                    reaction: unseen(competition)
                )
            }
            .buttonStyle(CompetitionRowButtonStyle())
        }
    }

    /// Inside a row panel the line sits past the badge.
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
        }
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
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Theme.tertiary)
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
                    if isReinviteInFlight {
                        ProgressView()
                    } else {
                        Text(
                            "Challenge \(LocalCompetitionIdentity.opponentDisplayName) Again"
                        )
                    }
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

    /// Closed challenges stay in the dashboard for a day, so the hidden
    /// count alone would drop the button right after a decline.
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

    /// Only the first-time empty Home ("No matches yet") offers practice.
    private var offersPractice: Bool {
        practice != nil && publication.source == .remoteParticipants && records.isEmpty
    }

    private func issueBanner(_ summary: String) -> some View {
        Label(summary, systemImage: "exclamationmark.triangle.fill")
            .font(.subheadline.weight(.medium))
            .foregroundStyle(Theme.ink)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .themePanel(cornerRadius: 16)
            .accessibilityLabel("Match status. \(summary)")
    }
}

/// The competition in play, drawn flat on the page like the mark: your
/// score in amber, the opponent's in ink, and the week at a glance below.
/// Compact cards sit under a LIVE group label, so they drop the live mark
/// and the details footer.
private struct CompetitionHeroCard: View {
    let competition: LocalCompetitionPresentation
    let source: CompetitionPublicationSource
    var isCompact = false
    var belt: CompetitionBelt? = nil
    /// An unseen reaction from the other person.
    var reaction: CompetitionReaction? = nil

    @Environment(\.locale) private var locale
    @Environment(\.timeZone) private var timeZone

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            statusRow

            if let holder = belt?.holder {
                CompetitionBeltChip(
                    holder: holder,
                    text: competitionBeltStandingText(
                        holder,
                        opponentName: competition.opponentDisplayName
                    )
                )
            }

            if competitionShouldShowScores(competition.lifecycle) {
                HeroScoreboard(competition: competition, isCompact: isCompact)
                statement
                    .font(.body)
                    .foregroundStyle(Theme.secondary)
            } else {
                scheduledHeadline
            }

            CompetitionWeekStrip(
                days: competition.days,
                currentDayOrdinal: competition.currentDayOrdinal
            )

            if let reaction {
                Divider().overlay(Theme.hairline)
                CompetitionReactionLine(
                    reaction: reaction,
                    opponentName: competition.opponentDisplayName
                )
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
                    Text("MATCH DETAILS")
                        .font(.themeLabel)
                        .tracking(1.4)
                    Image(systemName: "arrow.right")
                        .font(.footnote.weight(.bold))
                }
                .foregroundStyle(Theme.ink)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var statusRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                statusLeading
                Spacer(minLength: 8)
                statusTrailing
            }
            VStack(alignment: .leading, spacing: 4) {
                statusLeading
                statusTrailing
            }
        }
        .font(.themeLabel)
        .tracking(1.2)
        .textCase(.uppercase)
    }

    private var statusLeading: some View {
        HStack(spacing: 8) {
            if isLive {
                Circle()
                    .fill(Theme.ink)
                    .frame(width: 8, height: 8)
                Text("LIVE")
                    .foregroundStyle(Theme.ink)
            }
            Text(status.title)
                .foregroundStyle(Theme.secondary)
        }
    }

    @ViewBuilder
    private var statusTrailing: some View {
        if let timing = status.timing {
            Text(timing)
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var status: CompetitionStatusText {
        competitionStatusText(competition, style: .card, locale: locale, timeZone: timeZone)
    }

    private var isLive: Bool {
        guard !isCompact else { return false }
        switch competition.lifecycle {
        case .active, .endsToday: return true
        default: return false
        }
    }

    private var statement: Text {
        competitionLeadText(
            userPoints: competition.userPoints,
            opponentPoints: competition.opponentPoints,
            opponentDisplayName: competition.opponentDisplayName,
            locale: locale
        )
    }

    private var scheduledHeadline: some View {
        VStack(alignment: .leading, spacing: 4) {
            (Text("YOU")
                .foregroundStyle(Theme.you)
                + Text("  VS  ").foregroundStyle(Theme.tertiary)
                + Text(competition.opponentDisplayName.uppercased(with: .current))
                .foregroundStyle(Theme.ink))
                .font(.title2.weight(.heavy).width(.condensed))
            Text("Scores begin Day 1.")
                .font(.body)
                .foregroundStyle(Theme.secondary)
        }
    }
}

private struct HeroScoreboard: View {
    let competition: LocalCompetitionPresentation

    @ScaledMetric private var scoreSize: CGFloat
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(competition: LocalCompetitionPresentation, isCompact: Bool) {
        self.competition = competition
        _scoreSize = ScaledMetric(wrappedValue: isCompact ? 40 : 64, relativeTo: .largeTitle)
    }

    var body: some View {
        layout {
            side(
                name: "You",
                points: competition.userPoints,
                color: Theme.you,
                trailing: false
            )
            if !isStacked {
                Rectangle()
                    .fill(Theme.outline)
                    .frame(width: 2, height: scoreSize)
                    .rotationEffect(.degrees(12))
                    .accessibilityHidden(true)
            }
            side(
                name: competition.opponentDisplayName,
                points: competition.opponentPoints,
                color: Theme.ink,
                trailing: !isStacked
            )
        }
    }

    private var isStacked: Bool {
        dynamicTypeSize.isAccessibilitySize
    }

    private var layout: AnyLayout {
        isStacked
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            : AnyLayout(HStackLayout(alignment: .bottom, spacing: 8))
    }

    private func side(
        name: String,
        points: Double,
        color: Color,
        trailing: Bool
    ) -> some View {
        VStack(alignment: trailing ? .trailing : .leading, spacing: 2) {
            Text(name.uppercased(with: .current))
                .font(.themeLabel)
                .tracking(1.4)
            Text(competitionPointsText(points))
                .font(.score(size: scoreSize).monospacedDigit())
        }
        .foregroundStyle(color)
        .frame(maxWidth: .infinity, alignment: trailing ? .trailing : .leading)
    }
}

/// One competition in a grouped list; the list's panel draws the surface.
private struct CompetitionSharingRow: View {
    let competition: LocalCompetitionPresentation
    let source: CompetitionPublicationSource
    var caption: String? = nil
    /// The person page lists one person's weeks, so it drops the name.
    var showsName = true
    /// The person page marks the weeks the belt changed hands.
    var beltHolder: CompetitionBeltHolder? = nil
    /// Recent results: an unseen reaction from the other person.
    var reaction: CompetitionReaction? = nil

    @ScaledMetric(relativeTo: .headline) private var badgeSize: CGFloat = 40
    @Environment(\.locale) private var locale
    @Environment(\.timeZone) private var timeZone

    var body: some View {
        // The reaction line sits under the row, so it never decides
        // whether the score fits beside the name.
        VStack(alignment: .leading, spacing: 10) {
            rowContent
            if let reaction {
                CompetitionReactionLine(
                    reaction: reaction,
                    opponentName: competition.opponentDisplayName
                )
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
                HStack(alignment: .top, spacing: 14) {
                    badge
                    identity
                    Spacer(minLength: 0)
                }
                HStack {
                    if let beltHolder {
                        CompetitionBeltMark(holder: beltHolder)
                    }
                    if competitionShouldShowScores(competition.lifecycle) {
                        trailingScore
                    }
                    Spacer()
                    trailingMark
                }
            }
        }
    }

    @ViewBuilder
    private var badge: some View {
        if let outcome = sharingOutcome(competition.lifecycle) {
            CompetitionOutcomeChip(outcome: outcome)
        } else {
            Text(competition.opponentDisplayName.prefix(1).uppercased())
                .font(.headline.weight(.heavy).width(.condensed))
                .foregroundStyle(Theme.ink)
                .frame(width: badgeSize, height: badgeSize)
                .background(Theme.control, in: Circle())
                .accessibilityHidden(true)
        }
    }

    private var identity: some View {
        VStack(alignment: .leading, spacing: 4) {
            if showsName {
                Text(competition.opponentDisplayName)
                    .font(.headline)
                    .foregroundStyle(Theme.ink)
            }
            // Without a name, the status line is the row's title.
            Text(statusText)
                .font(showsName ? .subheadline.weight(.medium) : .headline)
                .foregroundStyle(statusColor)
            if let caption {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(Theme.secondary)
            }
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

    // A finished week carries its dates, so repeat opponents stay apart.
    private var statusText: String {
        competitionHomeStatusLine(competition, locale: locale, timeZone: timeZone)
    }

    // Your wins read in your color; everything else stays neutral.
    private var statusColor: Color {
        if sharingOutcome(competition.lifecycle) == .win { return Theme.you }
        return showsName ? Theme.secondary : Theme.ink
    }

    private var trailingScore: some View {
        let digits = sharingFractionDigits(competition)
        return (Text(competitionPointsText(competition.userPoints, fractionDigits: digits, locale: locale))
            .foregroundStyle(Theme.you)
            + Text(" / ").foregroundStyle(Theme.faint)
            + Text(competitionPointsText(competition.opponentPoints, fractionDigits: digits, locale: locale))
            .foregroundStyle(Theme.ink))
            .font(.title3.weight(.heavy).width(.condensed).monospacedDigit())
    }

    // A challenge waiting on you says what tapping it does.
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
        } else {
            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(Theme.tertiary)
        }
    }
}

/// W, L or T, colored by who won: amber is you, ink is them.
private struct CompetitionOutcomeChip: View {
    let outcome: CompetitionOutcome

    @ScaledMetric(relativeTo: .headline) private var size: CGFloat = 32

    var body: some View {
        Text(letter)
            .font(.headline.weight(.heavy).width(.condensed))
            .foregroundStyle(foreground)
            .padding(4)
            .frame(minWidth: size, minHeight: size)
            .background(fill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                if outcome == .tie {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
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

/// The belt: a strap with a plate, in the playbook's 44×24 geometry. The
/// plate is amber when you hold it, ink when they do. Words carry the meaning.
struct CompetitionBeltMark: View {
    let holder: CompetitionBeltHolder
    var width: CGFloat = 22

    var body: some View {
        let unit = width / 44
        ZStack {
            RoundedRectangle(cornerRadius: 3 * unit, style: .continuous)
                .fill(Theme.ink)
                .frame(width: width, height: 10 * unit)
            RoundedRectangle(cornerRadius: 5 * unit, style: .continuous)
                .fill(holder == .you ? Theme.youFill : Theme.ink)
                .frame(width: 20 * unit, height: 20 * unit)
            RoundedRectangle(cornerRadius: 2 * unit, style: .continuous)
                .fill(Theme.ground)
                .frame(width: 10 * unit, height: 10 * unit)
        }
        .frame(width: width, height: width * 24 / 44)
        .accessibilityHidden(true)
    }
}

/// "You hold the belt" on a Home card.
private struct CompetitionBeltChip: View {
    let holder: CompetitionBeltHolder
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            CompetitionBeltMark(holder: holder)
            Text(text)
                .font(.themeLabel)
                .tracking(1.2)
                .textCase(.uppercase)
                .foregroundStyle(holder == .you ? Theme.you : Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        // A capsule at one line; a rounded rectangle once the text wraps, so
        // the outline never crosses the letters at large sizes.
        .background(Theme.ground, in: chipShape)
        .overlay(chipShape.strokeBorder(Theme.hairline))
    }

    private var chipShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
    }
}

/// An outgoing challenge that closed in the last day: what happened, and the
/// way to send it again. It is not a navigation button.
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
                Text(competition.opponentDisplayName.prefix(1).uppercased())
                    .font(.headline.weight(.heavy).width(.condensed))
                    .foregroundStyle(Theme.ink)
                    .frame(width: badgeSize, height: badgeSize)
                    .background(Theme.control, in: Circle())
                    .accessibilityHidden(true)
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
                    if isInFlight {
                        ProgressView()
                    } else {
                        Text("Challenge \(competition.opponentDisplayName) Again")
                    }
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

/// A Recent results row that reveals Archive when swiped left. Home is a
/// plain VStack, so `List.swipeActions` isn't available. The action stays a
/// real button for VoiceOver, Switch Control and Voice Control.
private struct CompetitionArchiveSwipeRow<Row: View>: View {
    let id: CompetitionID
    let isInFlight: Bool
    let label: String
    let archive: () -> Void
    @ViewBuilder let row: () -> Row

    @ScaledMetric private var actionWidth: CGFloat = 96

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 0) {
                row()
                    .containerRelativeFrame(.horizontal)
                Button(action: archive) {
                    Group {
                        if isInFlight {
                            ProgressView()
                                .tint(Theme.onInk)
                        } else {
                            Text("Archive")
                                .font(.subheadline.weight(.semibold))
                        }
                    }
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

/// A problem with one match, under its row or card and at the top of its
/// screens. Retry refreshes everything and waits for it.
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

/// The record per person, styled: wins in your color, losses in ink and
/// ties neutral. The same words as `competitionHistorySummaryText`.
private func competitionHistorySummary(_ records: [CompetitionOpponentRecord]) -> Text {
    var text = Text("")
    for (index, record) in records.prefix(2).enumerated() {
        if index > 0 { text = text + Text(" · ") }
        text = text + Text(verbatim: "\(record.opponentDisplayName) ") + competitionRecordText(record)
    }
    if records.count > 2 {
        text = text + Text(" · \(records.count - 2) more")
    }
    return text
}

private func competitionRecordText(_ record: CompetitionOpponentRecord) -> Text {
    var text = Text(String(record.wins)).foregroundStyle(Theme.you).bold()
        + Text("–")
        + Text(String(record.losses)).foregroundStyle(Theme.ink)
    if record.ties > 0 {
        text = text + Text("–") + Text(String(record.ties)).foregroundStyle(Theme.secondary)
    }
    return text
}

/// One person's record in History, with who holds the belt. It opens the
/// person's page; each week below opens its result.
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
            [record.accessibilityText, beltAccessibilityText, "Latest: \(line)"]
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

    /// "You hold the belt, 1 week".
    private var beltAccessibilityText: String? {
        guard let current = record.belt.current, let holder = record.belt.holder else {
            return nil
        }
        return "\(competitionBeltStandingText(holder, opponentName: record.opponentDisplayName)), \(competitionWeeksText(current.weeks))"
    }

    private var badge: some View {
        Text(record.opponentDisplayName.prefix(1).uppercased())
            .font(.headline.weight(.heavy).width(.condensed))
            .foregroundStyle(Theme.ink)
            .frame(width: badgeSize, height: badgeSize)
            .background(Theme.control, in: Circle())
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
            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(Theme.tertiary)
        }
    }

    private var line: String {
        competitionHomeStatusLine(record.latest, locale: locale, timeZone: timeZone)
    }
}

/// Finished weeks: a record per person, then every week newest first.
struct CompetitionHistoryView: View {
    let publication: LocalCompetitionPublication

    @Environment(\.locale) private var locale
    @Environment(\.timeZone) private var timeZone

    var body: some View {
        let weeks = competitionHistoryWeeks(publication.dashboard.competitions)
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if weeks.isEmpty {
                    Text("Finished matches appear here.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    recordSection(weeks)
                    weeksSection(weeks)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(Theme.ground)
        .navigationTitle("History")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func recordSection(_ weeks: [LocalCompetitionPresentation]) -> some View {
        let records = competitionOpponentRecords(publication.dashboard.competitions)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                SectionLabel("RECORD")
                Spacer(minLength: 8)
                Text(weeks.count == 1 ? "1 WEEK" : "\(weeks.count) WEEKS")
                    .font(.themeLabel)
                    .tracking(1.2)
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
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("competition.rivalry")
    }

    private func weeksSection(_ weeks: [LocalCompetitionPresentation]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("WEEKS")
                .padding(.horizontal, 4)

            VStack(spacing: 0) {
                ForEach(Array(weeks.enumerated()), id: \.element.id) { index, competition in
                    if index > 0 {
                        CompetitionRowDivider()
                    }
                    NavigationLink(
                        value: CompetitionHomeRoute.competition(competition.id)
                    ) {
                        CompetitionSharingRow(
                            competition: competition,
                            source: publication.source
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
                        )
                        .accessibilityHint("Opens this match")
                    }
                    .buttonStyle(CompetitionRowButtonStyle())
                    .accessibilityIdentifier(competitionSharingIdentifier(competition))
                }
            }
            .themePanel()
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
    }
}

/// One person's page, opened from their History record: the record, who
/// holds the belt and every week with them. A summary, so no primary action.
struct CompetitionPersonView: View {
    let publication: LocalCompetitionPublication
    let opponentIdentity: String

    @Environment(\.locale) private var locale
    @Environment(\.timeZone) private var timeZone
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .largeTitle) private var recordSize: CGFloat = 64

    var body: some View {
        let competitions = publication.dashboard.competitions
        let record = competitionOpponentRecords(competitions)
            .first { $0.opponentIdentity == opponentIdentity }
        // Newest first, like History.
        let weeks = competitionHistoryWeeks(competitions)
            .filter { $0.opponentIdentity == opponentIdentity }
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if let record, !weeks.isEmpty {
                    header(record, weekCount: weeks.count)
                    beltPanel(record, weeks: weeks)
                    weeksSection(record, weeks)
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
        }
        .background(Theme.ground)
        .navigationTitle(record?.opponentDisplayName ?? "")
        .navigationBarTitleDisplayMode(.inline)
    }

    // AnyLayout, not ViewThatFits, which the Dynamic Type audit flags.
    private var rowLayout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 8))
    }

    // At accessibility sizes the mark sits above the title, so it doesn't
    // float beside a wrapped title or squeeze it.
    private var titleLayout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(spacing: 10))
    }

    private func header(_ record: CompetitionOpponentRecord, weekCount: Int) -> some View {
        rowLayout {
            competitionRecordText(record)
                .font(.score(size: recordSize).monospacedDigit())
            if !dynamicTypeSize.isAccessibilitySize {
                Spacer(minLength: 8)
            }
            Text(competitionWeeksText(weekCount).uppercased())
                .font(.themeLabel)
                .tracking(1.2)
                .foregroundStyle(Theme.secondary)
        }
        .padding(.horizontal, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(record.accessibilityText). \(competitionWeeksText(weekCount))")
        .accessibilityIdentifier("competition.person.record")
    }

    private func beltPanel(
        _ record: CompetitionOpponentRecord,
        weeks: [LocalCompetitionPresentation]
    ) -> some View {
        let belt = record.belt
        let name = record.opponentDisplayName
        return VStack(alignment: .leading, spacing: 8) {
            titleLayout {
                if let holder = belt.holder {
                    CompetitionBeltMark(holder: holder, width: 44)
                }
                Text(beltTitle(belt, name: name))
                    .font(.headline)
                    .foregroundStyle(belt.holder == .you ? Theme.you : Theme.ink)
            }
            if belt.holder != nil, let current = belt.current,
               let since = sinceText(current, weeks: weeks) {
                Text(since)
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondary)
            }
            if belt.changes > 0 {
                Rectangle()
                    .fill(Theme.hairline)
                    .frame(height: 1)
                    .padding(.vertical, 4)
                if let longest = belt.longest {
                    statRow(
                        "Longest reign",
                        "\(longest.holder == .you ? "You" : name) · \(competitionWeeksText(longest.weeks))"
                    )
                }
                statRow("Title changes", String(belt.changes))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .themePanel()
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("competition.person.belt")
    }

    private func beltTitle(_ belt: CompetitionBelt, name: String) -> String {
        if belt.isRetired { return "The belt is retired" }
        guard let holder = belt.holder else { return "No one holds the belt yet" }
        return competitionBeltStandingText(holder, opponentName: name)
    }

    /// "Since Nov 8 · 1 week": the last day of the week that took it.
    private func sinceText(
        _ current: CompetitionBeltReign,
        weeks: [LocalCompetitionPresentation]
    ) -> String? {
        guard let schedule = weeks.first(where: { $0.id == current.startID })?
            .acceptedConfiguration?.schedule,
            let lastDay = try? schedule.calendar.sevenDayWindow(startingOn: schedule.startDay).last
        else { return nil }
        let day = competitionDayText(
            lastDay,
            weekday: false,
            now: publication.evaluatedAt,
            locale: locale,
            timeZone: timeZone
        )
        return "Since \(day) · \(competitionWeeksText(current.weeks))"
    }

    private func statRow(_ title: String, _ value: String) -> some View {
        rowLayout {
            Text(title)
                .foregroundStyle(Theme.secondary)
            if !dynamicTypeSize.isAccessibilitySize {
                Spacer(minLength: 8)
            }
            Text(value)
                .bold()
                .foregroundStyle(Theme.ink)
        }
        .font(.subheadline)
    }

    private func weeksSection(
        _ record: CompetitionOpponentRecord,
        _ weeks: [LocalCompetitionPresentation]
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("WEEKS")
                .padding(.horizontal, 4)

            VStack(spacing: 0) {
                ForEach(Array(weeks.enumerated()), id: \.element.id) { index, competition in
                    if index > 0 {
                        CompetitionRowDivider()
                    }
                    let took = tookText(record.belt.events[competition.id], name: record.opponentDisplayName)
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
                }
            }
            .themePanel()
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
    }

    /// Only weeks where the belt changed hands carry the mark.
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

/// Home's stack. History, while open, sits under any person page and
/// competition opened from it.
enum CompetitionHomeRoute: Hashable {
    case history
    /// One person's page, by opponent identity; only pushed from History.
    case person(String)
    case competition(CompetitionID)

    /// One stack from a host's competition path, its History flag and the
    /// person open from History, so the host keeps owning what is open.
    static func stack(
        path: Binding<[CompetitionID]>,
        showsHistory: Binding<Bool>,
        person: Binding<String?>
    ) -> Binding<[CompetitionHomeRoute]> {
        Binding(
            get: {
                let history: [CompetitionHomeRoute] = showsHistory.wrappedValue
                    ? [.history] + (person.wrappedValue.map { [.person($0)] } ?? [])
                    : []
                return history
                    + path.wrappedValue.map(CompetitionHomeRoute.competition)
            },
            set: { routes in
                showsHistory.wrappedValue = routes.first == .history
                person.wrappedValue = routes.lazy.compactMap { route -> String? in
                    guard case let .person(identity) = route else { return nil }
                    return identity
                }.first
                path.wrappedValue = routes.compactMap { route in
                    guard case let .competition(id) = route else {
                        return nil
                    }
                    return id
                }
            }
        )
    }
}

/// Home's + button. It opens the new-challenge drawer.
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

/// The hairline between grouped rows, inset past the badge.
struct CompetitionRowDivider: View {
    var inset: CGFloat = 70

    var body: some View {
        Rectangle()
            .fill(Theme.hairline)
            .frame(height: 1)
            .padding(.leading, inset)
    }
}

/// The mark with the opponent's block as a dashed outline: nobody to play yet.
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

// Same 100×80 geometry as BrandMark's private polygons.
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

/// Two decimals only on a decided result whose whole points would match.
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
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.14),
                value: configuration.isPressed
            )
    }
}

/// Rows inside one panel highlight in place; scaling would break its edges.
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

/// A lifecycle in words: the same state reads the same on every screen.
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
    // Only a tallying match with a deadline still ahead says when it ends.
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
    now: Date = Date(),
    locale: Locale = .current,
    timeZone: TimeZone = .current
) -> CompetitionStatusText {
    let days = schedule.flatMap {
        try? $0.calendar.sevenDayWindow(startingOn: $0.startDay)
    }
    let bounds = schedule.flatMap(competitionScheduleBoundaries)
    // The calendar's zone, only when its offset differs from the phone's.
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
    let lifecycle: String = switch competition.lifecycle {
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
    return "competition.sharing.\(lifecycle).\(competition.id.rawValue.uuidString.lowercased())"
}

/// The top banner: only problems that affect everything, or a match that
/// isn't drawn with its own problem line.
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

// MARK: Home layout

/// Home's groups at one instant. Each list is already in display order.
struct CompetitionHomeLayout: Equatable {
    let hero: LocalCompetitionPresentation?
    let needsYou: [LocalCompetitionPresentation]
    /// Empty when the single live match is the hero.
    let live: [LocalCompetitionPresentation]
    /// Scheduled, outgoing challenges waiting, then closed outgoing ones.
    let upNext: [LocalCompetitionPresentation]
    let recentResults: [LocalCompetitionPresentation]

    var isEmpty: Bool {
        hero == nil && needsYou.isEmpty && live.isEmpty && upNext.isEmpty
            && recentResults.isEmpty
    }

    var allItems: [LocalCompetitionPresentation] {
        [hero].compactMap { $0 } + needsYou + live + upNext + recentResults
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

    // One live match leads as the big card; with none live, the soonest
    // scheduled match does. Two or more live get equal cards. A practice
    // leads only when no real match is live or scheduled.
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

/// Sorts by the first comparison that differs; the UUID breaks ties so the
/// order is stable.
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

/// The start of the 4th day after the last day, and never before the start of
/// the 2nd day after the week finished, both in the match calendar.
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

/// PR 1's `.row` line, plus " · Expires {moment}" for a pending challenge whose
/// expiry is still ahead. Rows, the VoiceOver summary and History all use it.
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

/// What a closed challenge says on Home and on its own screen.
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

// MARK: History

struct CompetitionOpponentRecord: Equatable {
    let opponentIdentity: String
    /// From the newest week, so a rename shows the current name.
    let opponentDisplayName: String
    let wins: Int
    let losses: Int
    let ties: Int
    let latest: LocalCompetitionPresentation
    var belt: CompetitionBelt = .vacant

    /// "2–1", or "2–1–1" with ties.
    var text: String {
        ([wins, losses] + (ties > 0 ? [ties] : [])).map(String.init).joined(separator: "–")
    }

    /// "Hermes, 2 wins, 1 loss", plus ", 1 tie" with ties.
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

/// Every finished week, newest first. Practice never counts.
func competitionHistoryWeeks(
    _ competitions: [LocalCompetitionPresentation]
) -> [LocalCompetitionPresentation] {
    competitionHomeSorted(competitions.filter { $0.terminalResult != nil && !$0.isPractice }, [
        competitionAscending {
            -(
                $0.acceptedConfiguration.flatMap { competitionScheduleBoundaries($0.schedule)?.end }
                    ?? $0.terminalResult?.completedAt ?? .distantPast
            ).timeIntervalSinceReferenceDate
        },
        competitionAscending {
            -($0.terminalResult?.completedAt ?? .distantPast).timeIntervalSinceReferenceDate
        },
    ])
}

/// One record per person (by identity, not name), ordered by latest week.
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
                weeks.compactMap { week in
                    week.terminalResult.map {
                        (
                            id: week.id,
                            end: week.acceptedConfiguration.flatMap {
                                competitionScheduleBoundaries($0.schedule)?.end
                            },
                            outcome: $0.outcome
                        )
                    }
                },
                isRetired: latest.opponentDisplayName == competitionFormerCompetitorName
            )
        )
    }
}

/// "Hermes 2–1 · Andy 1–0 · 2 more": the two people with the latest weeks.
func competitionHistorySummaryText(_ records: [CompetitionOpponentRecord]) -> String {
    let shown = records.prefix(2).map { "\($0.opponentDisplayName) \($0.text)" }
    let more = records.count > 2 ? ["\(records.count - 2) more"] : []
    return (shown + more).joined(separator: " · ")
}

/// "Hermes, 2 wins, 1 loss. Andy, 1 win, 0 losses. 2 more people"
func competitionHistorySummaryAccessibilityText(_ records: [CompetitionOpponentRecord]) -> String {
    let more = records.count - 2
    let shown = records.prefix(2).map(\.accessibilityText)
    let extra = more > 0 ? ["\(more) more \(more == 1 ? "person" : "people")"] : []
    return (shown + extra).joined(separator: ". ")
}

// MARK: Belt

/// The reserved name of a deleted account (profiles_identity_state_check).
let competitionFormerCompetitorName = "Former competitor"

enum CompetitionBeltHolder: Equatable, Sendable { case you, them }

/// What one finished week did to the belt.
enum CompetitionBeltEvent: Equatable, Sendable {
    /// A tie before anyone held it.
    case vacant
    /// The winner took it; `fromWeeks` is the other person's reign, nil on the first win.
    case took(by: CompetitionBeltHolder, fromWeeks: Int?)
    /// The holder won again or tied; `weeks` counts the reign including this week.
    case kept(by: CompetitionBeltHolder, weeks: Int)
}

struct CompetitionBeltReign: Equatable, Sendable {
    let holder: CompetitionBeltHolder
    let weeks: Int
    let startID: CompetitionID
}

struct CompetitionBelt: Equatable, Sendable {
    let current: CompetitionBeltReign?
    let longest: CompetitionBeltReign?
    /// Weeks the belt went to someone new, the first win included.
    let changes: Int
    let events: [CompetitionID: CompetitionBeltEvent]
    let isRetired: Bool
    /// Nil before the first decided week and once the other person's account is deleted.
    var holder: CompetitionBeltHolder? { isRetired ? nil : current?.holder }
    static let vacant = Self(current: nil, longest: nil, changes: 0, events: [:], isRetired: false)
}

/// One pair's finished weeks in any order. The fold sorts them (schedule end,
/// then uuid) so History and the notification planner can't disagree.
func competitionBelt(
    _ weeks: [(id: CompetitionID, end: Date?, outcome: CompetitionOutcome)],
    isRetired: Bool = false
) -> CompetitionBelt {
    let ordered = weeks.sorted {
        ($0.end ?? .distantPast, $0.id.rawValue.uuidString)
            < ($1.end ?? .distantPast, $1.id.rawValue.uuidString)
    }
    var current: CompetitionBeltReign?
    var longest: CompetitionBeltReign?
    var changes = 0
    var events: [CompetitionID: CompetitionBeltEvent] = [:]
    for week in ordered {
        let winner: CompetitionBeltHolder? = switch week.outcome {
        case .win: .you
        case .loss: .them
        case .tie: nil
        }
        if let reign = current, winner == nil || winner == reign.holder {
            current = CompetitionBeltReign(
                holder: reign.holder,
                weeks: reign.weeks + 1,
                startID: reign.startID
            )
            events[week.id] = .kept(by: reign.holder, weeks: reign.weeks + 1)
        } else if let winner {
            events[week.id] = .took(by: winner, fromWeeks: current?.weeks)
            current = CompetitionBeltReign(holder: winner, weeks: 1, startID: week.id)
            changes += 1
        } else {
            events[week.id] = .vacant
        }
        // >=: on equal length the more recent reign is the longest.
        if let reign = current, reign.weeks >= (longest?.weeks ?? 0) { longest = reign }
    }
    return CompetitionBelt(
        current: current,
        longest: longest,
        changes: changes,
        events: events,
        isRetired: isRetired
    )
}

/// The belt event of one finished match, from its pair's record.
func competitionBeltEvent(
    for competition: LocalCompetitionPresentation,
    in competitions: [LocalCompetitionPresentation]
) -> CompetitionBeltEvent? {
    // An earlier match with them still running could reorder the fold, so
    // "took"/"kept" isn't settled yet (and a shared image can't change later).
    guard !competitionBeltWaitsOnAnEarlierMatch(competition, in: competitions) else { return nil }
    return competitionOpponentRecords(competitions)
        .first { $0.opponentIdentity == competition.opponentIdentity }?
        .belt.events[competition.id]
}

/// True while an earlier match with the same person hasn't finished, so its
/// result could still move the belt ("going in" is not known yet).
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

/// "1 week" / "3 weeks".
func competitionWeeksText(_ count: Int) -> String { count == 1 ? "1 week" : "\(count) weeks" }

/// "You hold the belt" / "Sam holds the belt".
func competitionBeltStandingText(_ holder: CompetitionBeltHolder, opponentName: String) -> String {
    holder == .you ? "You hold the belt" : "\(opponentName) holds the belt"
}

/// The result banner: on a take, or a reign of 3+ weeks; otherwise nil.
/// Every line stays true after the belt moves on.
func competitionBeltResultText(
    _ event: CompetitionBeltEvent,
    opponentName: String
) -> (holder: CompetitionBeltHolder, title: String, detail: String?)? {
    func name(_ holder: CompetitionBeltHolder) -> String { holder == .you ? "You" : opponentName }
    switch event {
    case let .took(holder, fromWeeks):
        let previous: CompetitionBeltHolder = holder == .you ? .them : .you
        return (
            holder,
            "\(name(holder)) took the belt",
            fromWeeks.map { "\(name(previous)) held it for \(competitionWeeksText($0))." }
        )
    case let .kept(holder, weeks) where weeks >= 3:
        return (holder, "\(name(holder)) kept the belt", "\(weeks) weeks in a row.")
    case .kept, .vacant:
        return nil
    }
}

// MARK: Problems on one match

enum CompetitionRowIssue: Equatable, Sendable {
    case command
    case refresh
    case activity
}

/// The strongest problem tied to one match: command, then refresh, then activity.
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
