import CompetitionCore
import SwiftUI

/// Home: what is in play right now, grouped as Needs you, Live, Up next and
/// Recent results. Creating a challenge opens in a drawer, finished weeks
/// live in History, and notifications and privacy live in Account.
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
    let challengeAgain: (CompetitionID) -> Void
    let archive: (CompetitionID) -> Void
    let commandIDsInFlight: Set<CompetitionID>
    let retry: () async -> Void

    // ponytail: in-memory, a dismissed row returns after relaunch within its 24 h; persist per profile if that annoys
    @State private var dismissedChallengeIDs: Set<CompetitionID> = []

    @Environment(\.locale) private var locale
    @Environment(\.timeZone) private var timeZone

    var body: some View {
        let layout = self.layout
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
                    VStack(alignment: .leading, spacing: 12) {
                        competitionButton(hero) {
                            CompetitionHeroCard(
                                competition: hero,
                                source: publication.source
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
                                VStack(alignment: .leading, spacing: 12) {
                                    competitionButton(competition) {
                                        CompetitionHeroCard(
                                            competition: competition,
                                            source: publication.source,
                                            isCompact: true
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

    /// Matches drawn on Home carry their own problem line, so the banner
    /// leaves them out.
    private func attributedIDs(_ layout: CompetitionHomeLayout) -> Set<CompetitionID> {
        Set(
            ([layout.hero].compactMap { $0 } + layout.needsYou + layout.live
                + layout.upNext + layout.recentResults).map(\.id)
        )
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
        let caption = competitionResultLeavesHome(competition).map {
            "Moves to History \(weekdayText($0.day, locale: locale))"
        }
        CompetitionArchiveSwipeRow(
            id: competition.id,
            isInFlight: commandIDsInFlight.contains(competition.id),
            label: "Archive. \(competition.opponentDisplayName). \(competitionHomeStatusLine(competition, locale: locale, timeZone: timeZone))",
            archive: { archive(competition.id) }
        ) {
            competitionButton(competition, caption: caption) {
                CompetitionSharingRow(
                    competition: competition,
                    source: publication.source,
                    caption: caption
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
                case .declined, .expired: true
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
            records.isEmpty ? "Challenge someone to start a match." : nil
        }
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

    @Environment(\.locale) private var locale
    @Environment(\.timeZone) private var timeZone

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            statusRow

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

    @ScaledMetric(relativeTo: .headline) private var badgeSize: CGFloat = 40
    @Environment(\.locale) private var locale
    @Environment(\.timeZone) private var timeZone

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) {
                badge
                identity
                Spacer(minLength: 8)
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
                    if competitionShouldShowScores(competition.lifecycle) {
                        trailingScore
                    }
                    Spacer()
                    trailingMark
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
        sharingOutcome(competition.lifecycle) == .win
            ? Theme.you
            : Theme.secondary
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

/// One person's record in History. It is a summary, so it doesn't open
/// anything; each week below opens its result.
private struct CompetitionRecordRow: View {
    let record: CompetitionOpponentRecord

    @ScaledMetric(relativeTo: .headline) private var badgeSize: CGFloat = 40
    @Environment(\.locale) private var locale
    @Environment(\.timeZone) private var timeZone

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) {
                badge
                identity
                Spacer(minLength: 8)
                recordText
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 14) {
                    badge
                    identity
                    Spacer(minLength: 0)
                }
                recordText
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(record.accessibilityText). Latest: \(line)")
        .accessibilityAddTraits(.isStaticText)
        .accessibilityIdentifier(
            "competition.record.\(record.latest.id.rawValue.uuidString.lowercased())"
        )
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
        competitionRecordText(record)
            .font(.title3.weight(.heavy).width(.condensed).monospacedDigit())
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
                    CompetitionRecordRow(record: record)
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
    timeZone: TimeZone = .current
) -> String {
    var parts = [
        competition.opponentDisplayName,
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
    // Only a tallying match with a deadline still ahead says when it ends.
    guard case .tallying = competition.lifecycle,
          style != .notification,
          let deadline = competition.tally?.bestAvailableDeadline,
          competition.evaluatedAt < deadline
    else {
        return base
    }
    return CompetitionStatusText(
        title: base.title,
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
    case .pending, .scheduled, .declined, .expired:
        return false
    case .active, .endsToday, .tallying, .completed, .archived:
        return true
    }
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
        case .declined, .expired:
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
        case let .declined(at, _), let .expired(at, _): at
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
    // scheduled match does. Two or more live get equal cards.
    var hero: LocalCompetitionPresentation?
    if live.count == 1 {
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
    case .declined(_, .outgoing), .expired(_, .outgoing): true
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

/// Every finished week, newest first.
func competitionHistoryWeeks(
    _ competitions: [LocalCompetitionPresentation]
) -> [LocalCompetitionPresentation] {
    competitionHomeSorted(competitions.filter { $0.terminalResult != nil }, [
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
            latest: latest
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
