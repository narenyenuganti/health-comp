import CompetitionCore
import SwiftUI

/// Home: what is in play right now. Creating a challenge opens in a drawer,
/// finished competitions and awards live in History, and notifications and
/// privacy live in Account.
struct CompetitionSharingView: View {
    let publication: LocalCompetitionPublication
    let inviteCreationStatus: CompetitionFeature.InviteCreationStatus
    let createdInviteLink: CompetitionInviteShareLink?
    @Binding var recipientCode: String
    let recipient: AuthenticatedProfile?
    let recipientStatus: CompetitionFeature.InviteRecipientStatus
    let findRecipient: () -> Void
    let createInvite: () -> Void
    /// Set by the host's + button and by the empty state.
    @Binding var isChallengePresented: Bool
    let selectCompetition: (CompetitionID) -> Void
    let openHistory: () -> Void
    let reinvite: () -> Void
    let isReinviteInFlight: Bool

    @Environment(\.locale) private var locale
    @Environment(\.timeZone) private var timeZone

    var body: some View {
        // A plain VStack keeps every card in the hierarchy, so scrolling to a
        // card works in both directions.
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if !publication.dashboard.issues.isEmpty {
                    issueBanner
                }

                if let hero = heroCompetition {
                    competitionButton(hero) {
                        CompetitionHeroCard(
                            competition: hero,
                            source: publication.source
                        )
                    }
                    .buttonStyle(CompetitionPressButtonStyle())
                }

                competitionSection

                if rivalry.completions > 0 {
                    historyButton
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(Theme.ground)
        .navigationTitle("Sharing")
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
        .sheet(isPresented: $isChallengePresented) {
            CreateCompetitionView(
                status: inviteCreationStatus,
                shareLink: createdInviteLink,
                timeZoneIdentifier: publication.timeZoneIdentifier,
                recipientCode: $recipientCode,
                recipient: recipient,
                recipientStatus: recipientStatus,
                findRecipient: findRecipient,
                create: createInvite
            )
        }
    }

    /// Archived competitions move to History.
    private var homeCompetitions: [LocalCompetitionPresentation] {
        publication.dashboard.competitions.filter {
            !sharingIsArchived($0.lifecycle)
        }
    }

    /// The first competition in play leads the page; a scheduled one leads
    /// only when nothing is in play yet.
    private var heroCompetition: LocalCompetitionPresentation? {
        homeCompetitions.first { sharingIsInPlay($0.lifecycle) }
            ?? homeCompetitions.first {
                if case .scheduled = $0.lifecycle { return true }
                return false
            }
    }

    private var otherCompetitions: [LocalCompetitionPresentation] {
        let heroID = heroCompetition?.id
        return homeCompetitions.filter { $0.id != heroID }
    }

    private var rivalry: CompetitionRivalrySummary {
        competitionRivalrySummary(publication.dashboard)
    }

    private func competitionButton<Content: View>(
        _ competition: LocalCompetitionPresentation,
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
                    )
                )
                .accessibilityHint("Opens this competition")
        }
        .accessibilityIdentifier(competitionSharingIdentifier(competition))
    }

    @ViewBuilder
    private var competitionSection: some View {
        if homeCompetitions.isEmpty {
            emptyState
        } else if !otherCompetitions.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel("MATCHES")
                    .padding(.horizontal, 4)

                VStack(spacing: 0) {
                    ForEach(
                        Array(otherCompetitions.enumerated()),
                        id: \.element.id
                    ) { index, competition in
                        if index > 0 {
                            CompetitionRowDivider()
                        }
                        competitionButton(competition) {
                            CompetitionSharingRow(
                                competition: competition,
                                source: publication.source
                            )
                        }
                        .buttonStyle(CompetitionRowButtonStyle())
                    }
                }
                .themePanel()
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
        }
    }

    private var historyButton: some View {
        Button(action: openHistory) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("History")
                        .font(.headline)
                        .foregroundStyle(Theme.ink)
                    (Text("\(rivalry.completions) completed · You won ")
                        + Text(String(rivalry.ownerWins))
                            .foregroundStyle(Theme.you)
                            .bold())
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
        .accessibilityHint("Opens finished competitions and awards")
        .accessibilityIdentifier("competition.history.open")
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            OpenSlotMark()
                .frame(width: 96)

            VStack(spacing: 6) {
                Text("No competition yet")
                    .font(.title3.weight(.heavy).width(.condensed))
                    .foregroundStyle(Theme.ink)
                Text(emptyStateDescription)
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondary)
            }
            .multilineTextAlignment(.center)

            if publication.source == .simulatedFixture,
               publication.dashboard.hiddenTerminalCompetitionCount > 0 {
                Button {
                    reinvite()
                } label: {
                    if isReinviteInFlight {
                        ProgressView()
                    } else {
                        Text(
                            "Invite \(LocalCompetitionIdentity.opponentDisplayName) Again"
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
        }
        .frame(maxWidth: .infinity)
        .padding(20)
        .themePanel()
    }

    private var emptyStateDescription: String {
        switch publication.source {
        case .simulatedFixture:
            publication.dashboard.hiddenTerminalCompetitionCount > 0
                ? "The previous invitation closed. You can invite \(LocalCompetitionIdentity.opponentDisplayName) again."
                : "A local invitation will appear here."
        case .remoteParticipants:
            "Create and share a private invitation to begin."
        }
    }

    private var issueBanner: some View {
        Label(
            competitionIssueSummary(publication.dashboard.issues),
            systemImage: "exclamationmark.triangle.fill"
        )
        .font(.subheadline.weight(.medium))
        .foregroundStyle(Theme.ink)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .themePanel(cornerRadius: 16)
        .accessibilityLabel(
            "Competition status. \(competitionIssueSummary(publication.dashboard.issues))"
        )
    }
}

/// The competition in play, drawn flat on the page like the mark: your
/// score in amber, the opponent's in ink, and the week at a glance below.
private struct CompetitionHeroCard: View {
    let competition: LocalCompetitionPresentation
    let source: CompetitionPublicationSource

    @Environment(\.locale) private var locale
    @Environment(\.timeZone) private var timeZone

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            statusRow

            if competitionShouldShowScores(competition.lifecycle) {
                HeroScoreboard(competition: competition)
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

            if let disclosure = competitionFixtureDisclosure(
                source: source,
                opponentDisplayName: competition.opponentDisplayName
            ) {
                Text(disclosure)
                    .font(.caption)
                    .foregroundStyle(Theme.secondary)
            }

            HStack(spacing: 6) {
                Text("MATCH DETAILS")
                    .font(.themeLabel)
                    .tracking(1.4)
                Image(systemName: "arrow.right")
                    .font(.footnote.weight(.bold))
            }
            .foregroundStyle(Theme.ink)
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
            Text(statusText)
                .foregroundStyle(Theme.secondary)
        }
    }

    @ViewBuilder
    private var statusTrailing: some View {
        if let endText {
            Text(endText)
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var isLive: Bool {
        switch competition.lifecycle {
        case .active, .endsToday: true
        default: false
        }
    }

    private var statusText: String {
        if case let .active(dayOrdinal) = competition.lifecycle {
            return "DAY \(dayOrdinal) OF 7"
        }
        return competitionSharingStatus(competition.lifecycle)
            .uppercased(with: .current)
    }

    private var endText: String? {
        switch competition.lifecycle {
        case .active, .scheduled:
            competition.acceptedConfiguration?.schedule
                .flatMap(competitionScheduleBoundaries)
                .map { "ENDS \(competitionDateTimeText($0.end, locale: locale, timeZone: timeZone))" }
        default:
            nil
        }
    }

    private var statement: Text {
        let margin = competition.userPoints - competition.opponentPoints
        if margin > 0 {
            return Text("You lead by ")
                + Text(competitionPointsText(margin))
                    .foregroundStyle(Theme.you)
                    .bold()
                + Text(".")
        }
        if margin < 0 {
            return Text(
                "\(competition.opponentDisplayName) leads by \(competitionPointsText(-margin))."
            )
        }
        return Text("All square.")
    }

    private var scheduledHeadline: some View {
        VStack(alignment: .leading, spacing: 4) {
            (Text(competition.ownerDisplayName.uppercased(with: .current))
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

    @ScaledMetric(relativeTo: .largeTitle) private var scoreSize: CGFloat = 64
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        layout {
            side(
                name: competition.ownerDisplayName,
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

    @ScaledMetric(relativeTo: .headline) private var badgeSize: CGFloat = 40

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) {
                badge
                identity
                Spacer(minLength: 8)
                if competitionShouldShowScores(competition.lifecycle) {
                    trailingScore
                }
                chevron
            }

            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 14) {
                    badge
                    identity
                    Spacer(minLength: 0)
                }
                HStack {
                    if competitionShouldShowScores(competition.lifecycle) {
                        trailingScore
                    }
                    Spacer()
                    chevron
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
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
            Text(competition.opponentDisplayName)
                .font(.headline)
                .foregroundStyle(Theme.ink)
            Text(statusText)
                .font(.subheadline.weight(.medium))
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

    // A finished week carries its dates, so repeat opponents stay apart.
    private var statusText: String {
        let status = competitionSharingStatus(competition.lifecycle)
        guard sharingOutcome(competition.lifecycle) != nil,
              let first = competition.days.first?.day,
              let last = competition.days.last?.day
        else {
            return status
        }
        return "\(status) · \(first.month)/\(first.day)–\(last.month)/\(last.day)"
    }

    // Your wins read in your color; everything else stays neutral.
    private var statusColor: Color {
        sharingOutcome(competition.lifecycle) == .win
            ? Theme.you
            : Theme.secondary
    }

    private var trailingScore: some View {
        (Text(competitionPointsText(competition.userPoints))
            .foregroundStyle(Theme.you)
            + Text(" / ").foregroundStyle(Theme.faint)
            + Text(competitionPointsText(competition.opponentPoints))
            .foregroundStyle(Theme.ink))
            .font(.title3.weight(.heavy).width(.condensed).monospacedDigit())
    }

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.caption.weight(.bold))
            .foregroundStyle(Theme.tertiary)
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

private struct CompetitionAwardDashboardRow: View {
    let award: LocalCompetitionAward
    let victoryCount: Int

    @Environment(\.locale) private var locale
    @Environment(\.timeZone) private var timeZone

    @ScaledMetric(relativeTo: .title3) private var discSize: CGFloat = 40

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: award.kind == .victory ? "trophy.fill" : "checkmark.seal.fill")
                .font(.title3)
                .foregroundStyle(award.kind == .victory ? Theme.onYouFill : Theme.ink)
                .frame(width: discSize, height: discSize)
                .background(
                    award.kind == .victory ? Theme.youFill : Theme.control,
                    in: Circle()
                )
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(
                    award.kind == .victory
                        ? "Victory Over \(award.friendDisplayName)"
                        : "Competition Complete"
                )
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.ink)
                Text(
                    competitionAwardEarnedText(
                        award.awardedAt,
                        locale: locale,
                        timeZone: timeZone
                    )
                )
                    .font(.caption)
                    .foregroundStyle(Theme.secondary)
                if award.kind == .victory {
                    Text(
                        competitionVictoryCountText(
                            victoryCount,
                            friendDisplayName: award.friendDisplayName
                        )
                    )
                    .font(.caption)
                    .foregroundStyle(Theme.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(minHeight: 64)
        .accessibilityElement(children: .combine)
    }
}

private struct CompetitionRivalrySummaryCard: View {
    let summary: CompetitionRivalrySummary

    @Environment(\.locale) private var locale
    @Environment(\.timeZone) private var timeZone

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack {
                    title
                    Spacer(minLength: 8)
                    completed
                }
                VStack(alignment: .leading, spacing: 4) {
                    title
                    completed
                }
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { tiles }
                VStack(spacing: 8) { tiles }
            }

            if let latestOwnerVictoryAt = summary.latestOwnerVictoryAt {
                Text(
                    "Latest victory \(competitionAwardDateText(latestOwnerVictoryAt, locale: locale, timeZone: timeZone))"
                )
                .font(.caption)
                .foregroundStyle(Theme.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("competition.rivalry")
    }

    private var title: some View {
        Text("COMPETITION HISTORY")
            .font(.themeLabel)
            .tracking(1.2)
            .foregroundStyle(Theme.ink)
    }

    private var completed: some View {
        Text("\(summary.completions) COMPLETED")
            .font(.themeLabel)
            .tracking(1.2)
            .foregroundStyle(Theme.secondary)
    }

    @ViewBuilder
    private var tiles: some View {
        tile(summary.ownerWins, "YOU WON", Theme.you)
        tile(summary.opponentWins, "THEY WON", Theme.ink)
        tile(summary.ties, "TIED", Theme.secondary)
    }

    private func tile(_ value: Int, _ title: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(String(value))
                .font(.title.weight(.heavy).width(.condensed).monospacedDigit())
                .foregroundStyle(color)
            Text(title)
                .font(.themeLabel)
                .tracking(1.2)
                .foregroundStyle(Theme.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .themePanel(cornerRadius: 14)
    }
}

/// Finished competitions and every award, kept off Home.
struct CompetitionHistoryView: View {
    let publication: LocalCompetitionPublication

    @Environment(\.locale) private var locale
    @Environment(\.timeZone) private var timeZone

    @State private var page: Page = .matches

    private enum Page: Hashable {
        case matches
        case awards
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                CompetitionRivalrySummaryCard(
                    summary: competitionRivalrySummary(publication.dashboard)
                )

                Picker("History", selection: $page) {
                    Text("Matches").tag(Page.matches)
                    Text("Awards").tag(Page.awards)
                }
                .pickerStyle(.segmented)

                switch page {
                case .matches:
                    matchList
                case .awards:
                    awardList
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(Theme.ground)
        .navigationTitle("History")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var finished: [LocalCompetitionPresentation] {
        publication.dashboard.competitions.filter {
            sharingOutcome($0.lifecycle) != nil
        }
    }

    private var matchList: some View {
        VStack(spacing: 0) {
            ForEach(Array(finished.enumerated()), id: \.element.id) {
                index,
                competition in
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
                    .accessibilityHint("Opens this competition")
                }
                .buttonStyle(CompetitionRowButtonStyle())
                .accessibilityIdentifier(competitionSharingIdentifier(competition))
            }
        }
        .themePanel()
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    @ViewBuilder
    private var awardList: some View {
        let awards = publication.dashboard.awards
        if awards.isEmpty {
            Text("Awards appear here when a competition finishes.")
                .font(.subheadline)
                .foregroundStyle(Theme.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(spacing: 0) {
                ForEach(Array(awards.enumerated()), id: \.element.id) {
                    index,
                    award in
                    CompetitionAwardDashboardRow(
                        award: award,
                        victoryCount: awards.filter {
                            $0.kind == .victory
                                && $0.friendDisplayName == award.friendDisplayName
                        }.count
                    )
                    if index < awards.count - 1 {
                        Rectangle()
                            .fill(Theme.hairline)
                            .frame(height: 1)
                            .padding(.leading, 68)
                    }
                }
            }
            .themePanel()
        }
    }
}

/// Home's stack. History, while open, sits under any competition opened
/// from it.
enum CompetitionHomeRoute: Hashable {
    case history
    case competition(CompetitionID)

    /// One stack from a host's competition path and its History flag, so
    /// the host keeps owning which competitions are open.
    static func stack(
        path: Binding<[CompetitionID]>,
        showsHistory: Binding<Bool>
    ) -> Binding<[CompetitionHomeRoute]> {
        Binding(
            get: {
                let history: [CompetitionHomeRoute] =
                    showsHistory.wrappedValue ? [.history] : []
                return history
                    + path.wrappedValue.map(CompetitionHomeRoute.competition)
            },
            set: { routes in
                showsHistory.wrappedValue = routes.first == .history
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
private struct CompetitionRowDivider: View {
    var body: some View {
        Rectangle()
            .fill(Theme.hairline)
            .frame(height: 1)
            .padding(.leading, 70)
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

private func sharingIsInPlay(
    _ lifecycle: LocalCompetitionLifecyclePresentation
) -> Bool {
    switch lifecycle {
    case .active, .endsToday, .tallying: true
    default: false
    }
}

private func sharingIsArchived(
    _ lifecycle: LocalCompetitionLifecyclePresentation
) -> Bool {
    if case .archived = lifecycle { return true }
    return false
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

private func sharingAccessibilitySummary(
    _ competition: LocalCompetitionPresentation,
    source: CompetitionPublicationSource,
    locale: Locale = .current,
    timeZone: TimeZone = .current
) -> String {
    var parts = [
        competition.opponentDisplayName,
        competitionSharingStatus(competition.lifecycle),
    ]
    if let disclosure = competitionFixtureDisclosure(
        source: source,
        opponentDisplayName: competition.opponentDisplayName
    ) {
        parts.append(disclosure)
    }
    let showsEnd: Bool
    switch competition.lifecycle {
    case .active, .scheduled: showsEnd = true
    default: showsEnd = false
    }
    if showsEnd,
       let schedule = competition.acceptedConfiguration?.schedule,
       let end = competitionScheduleBoundaries(schedule)?.end {
        parts.append("Ends \(competitionDateTimeText(end, locale: locale, timeZone: timeZone))")
    }
    if competitionShouldShowScores(competition.lifecycle) {
        parts.append(
            "\(competition.ownerDisplayName) \(competitionPointsText(competition.userPoints)) total points"
        )
        parts.append(
            "\(competition.opponentDisplayName) \(competitionPointsText(competition.opponentPoints)) total points"
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

func competitionSharingStatus(
    _ lifecycle: LocalCompetitionLifecyclePresentation
) -> String {
    switch lifecycle {
    case let .pending(direction, _, _):
        direction == .incoming ? "Incoming invitation" : "Outgoing invitation"
    case .declined: "Declined"
    case .expired: "Expired"
    case .scheduled: "Scheduled"
    case let .active(dayOrdinal): "Day \(dayOrdinal)"
    case .endsToday: "Ends Today"
    case .tallying: "Tallying Points"
    case let .completed(outcome, _, _), let .archived(outcome, _, _, _):
        switch outcome {
        case .win: "Won"
        case .loss: "Lost"
        case .tie: "Tied"
        }
    }
}

func competitionShouldShowScores(
    _ lifecycle: LocalCompetitionLifecyclePresentation
) -> Bool {
    switch lifecycle {
    case .pending, .scheduled, .declined, .expired:
        return false
    case .active, .endsToday, .tallying, .completed, .archived:
        return true
    }
}

struct CompetitionRivalrySummary: Equatable {
    let completions: Int
    let ownerWins: Int
    let opponentWins: Int
    let ties: Int
    let latestOwnerVictoryAt: Date?
}

func competitionRivalrySummary(
    _ dashboard: LocalCompetitionDashboard
) -> CompetitionRivalrySummary {
    let outcomes = dashboard.competitions.compactMap(\.terminalResult)
    return CompetitionRivalrySummary(
        completions: outcomes.count,
        ownerWins: outcomes.filter { $0.outcome == .win }.count,
        opponentWins: outcomes.filter { $0.outcome == .loss }.count,
        ties: outcomes.filter { $0.outcome == .tie }.count,
        latestOwnerVictoryAt: dashboard.awards
            .filter { $0.kind == .victory }
            .map(\.awardedAt)
            .max()
    )
}

func competitionVictoryCountText(
    _ count: Int,
    friendDisplayName: String
) -> String {
    "\(count) \(count == 1 ? "win" : "wins") against \(friendDisplayName)"
}

func competitionSharingIdentifier(
    _ competition: LocalCompetitionPresentation
) -> String {
    let lifecycle: String = switch competition.lifecycle {
    case .pending: "pending"
    case .declined: "declined"
    case .expired: "expired"
    case .scheduled: "scheduled"
    case .active: "active"
    case .endsToday: "ends-today"
    case .tallying: "tallying"
    case .completed: "completed"
    case .archived: "archived"
    }
    return "competition.sharing.\(lifecycle).\(competition.id.rawValue.uuidString.lowercased())"
}

func competitionIssueSummary(_ issues: [LocalCompetitionClientIssue]) -> String {
    if issues.contains(.storageUnavailable) {
        return "Local competition storage is unavailable."
    }
    if issues.contains(.authorizationUnavailable) {
        return "Activity authorization is unavailable."
    }
    if issues.contains(.remoteFailure) {
        return "Competition data could not be refreshed."
    }
    if issues.contains(.remoteUnavailable) {
        return "Unable to connect. HealthComp will keep trying."
    }
    if issues.contains(where: {
        if case .competitionFailures = $0 { return true }
        return false
    }) {
        return "Some competition activity could not be refreshed."
    }
    if issues.contains(where: {
        if case .activityFailures = $0 { return true }
        return false
    }) {
        return "Competition is available, but Activity could not be refreshed."
    }
    return "The latest competition action could not be completed."
}
