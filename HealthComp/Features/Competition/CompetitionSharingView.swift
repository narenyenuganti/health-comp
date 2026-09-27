import CompetitionCore
import SwiftUI

struct CompetitionSharingView: View {
    let publication: LocalCompetitionPublication
    let inviteCreationStatus: CompetitionFeature.InviteCreationStatus
    let createdInviteLink: CompetitionInviteShareLink?
    let createInvite: () -> Void
    let selectCompetition: (CompetitionID) -> Void
    let reinvite: () -> Void
    let isReinviteInFlight: Bool
    let notificationAuthorization:
        CompetitionNotificationAuthorizationState?
    let notificationAuthorizationRequestIsInFlight: Bool
    let requestNotificationAuthorization: () -> Void

    var body: some View {
        // A plain VStack keeps every card in the hierarchy, so scrolling to a
        // card works in both directions.
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                intro

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
                }

                notificationControls

                if publication.source == .remoteParticipants {
                    CreateCompetitionView(
                        status: inviteCreationStatus,
                        shareLink: createdInviteLink,
                        timeZoneIdentifier: publication.timeZoneIdentifier,
                        create: createInvite
                    )
                }

                competitionSection

                if !publication.dashboard.awards.isEmpty {
                    awardsSection
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(Theme.ground)
        .navigationTitle("Sharing")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // The bar shows only the mark and the avatar; the title stays for
            // VoiceOver and the navigation bar's identity.
            ToolbarItem(placement: .principal) {
                Color.clear
                    .frame(width: 1, height: 1)
                    .accessibilityHidden(true)
            }
        }
    }

    // The top line stays the page's invariant anchor.
    private var intro: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "lock.fill")
                .font(.caption)
                .accessibilityHidden(true)
            Text(heroDescription)
        }
        .font(.footnote)
        .foregroundStyle(Theme.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var heroDescription: String {
        switch publication.source {
        case .simulatedFixture:
            "Share a seven-day competition with Alex while your scores stay on this iPhone."
        case .remoteParticipants:
            "Compete privately with real people while raw Health data stays on this iPhone."
        }
    }

    /// The first competition in play leads the page; a scheduled one leads
    /// only when nothing is in play yet.
    private var heroCompetition: LocalCompetitionPresentation? {
        let competitions = publication.dashboard.competitions
        return competitions.first { sharingIsInPlay($0.lifecycle) }
            ?? competitions.first {
                if case .scheduled = $0.lifecycle { return true }
                return false
            }
    }

    private var otherCompetitions: [LocalCompetitionPresentation] {
        let heroID = heroCompetition?.id
        return publication.dashboard.competitions.filter { $0.id != heroID }
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
                        source: publication.source
                    )
                )
                .accessibilityHint("Opens this competition")
        }
        .buttonStyle(CompetitionPressButtonStyle())
        .accessibilityIdentifier(competitionSharingIdentifier(competition))
    }

    @ViewBuilder
    private var notificationControls: some View {
        switch notificationAuthorization {
        case .notDetermined:
            Button(action: requestNotificationAuthorization) {
                if notificationAuthorizationRequestIsInFlight {
                    ProgressView()
                } else {
                    Label(
                        "Enable Competition Notifications",
                        systemImage: "bell.badge.fill"
                    )
                }
            }
            .buttonStyle(SecondaryButtonStyle())
            .disabled(notificationAuthorizationRequestIsInFlight)
            .accessibilityIdentifier("competition.notifications.enable")

        case .denied:
            Label(
                "Competition notifications are disabled in Settings.",
                systemImage: "bell.slash.fill"
            )
            .font(.caption)
            .foregroundStyle(Theme.secondary)

        // Muting one person lives on the screens of their matches.
        case .authorized, .provisional, .ephemeral, nil:
            EmptyView()
        }
    }

    @ViewBuilder
    private var competitionSection: some View {
        if publication.dashboard.competitions.isEmpty {
            emptyState
        } else if !otherCompetitions.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel("MATCHES")
                    .padding(.horizontal, 4)

                ForEach(otherCompetitions) { competition in
                    competitionButton(competition) {
                        CompetitionSharingCard(
                            competition: competition,
                            source: publication.source
                        )
                    }
                }
            }
        }
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

    private var awardsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Awards")
                .padding(.horizontal, 4)

            CompetitionRivalrySummaryCard(
                summary: competitionRivalrySummary(publication.dashboard),
                timeZoneIdentifier: publication.timeZoneIdentifier
            )

            VStack(spacing: 0) {
                ForEach(Array(publication.dashboard.awards.enumerated()), id: \.element.id) {
                    index,
                    award in
                    CompetitionAwardDashboardRow(
                        award: award,
                        victoryCount: publication.dashboard.awards.filter {
                            $0.kind == .victory
                                && $0.friendDisplayName == award.friendDisplayName
                        }.count,
                        timeZoneIdentifier: publication.dashboard.competitions
                            .first(where: { $0.id == award.competitionID })?
                            .timeZoneIdentifier
                            ?? publication.timeZoneIdentifier
                    )
                    if index < publication.dashboard.awards.count - 1 {
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
/// score in amber, the opponent's in ink, and the week below.
private struct CompetitionHeroCard: View {
    let competition: LocalCompetitionPresentation
    let source: CompetitionPublicationSource

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

            CompetitionWeekChart(
                days: competition.days,
                currentDayOrdinal: competition.currentDayOrdinal,
                ownerName: competition.ownerDisplayName,
                opponentName: competition.opponentDisplayName
            )

            CompetitionRingLegend(
                opponentName: competition.opponentDisplayName
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
            competition.days.last.map { "ENDS \(weekdayText($0.day))" }
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

private struct CompetitionSharingCard: View {
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
        .themePanel()
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
            Text(competitionSharingStatus(competition.lifecycle))
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
    let timeZoneIdentifier: String

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
                        timeZoneIdentifier: timeZoneIdentifier
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
    let timeZoneIdentifier: String

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
                    "Latest victory \(competitionAwardDateText(latestOwnerVictoryAt, timeZoneIdentifier: timeZoneIdentifier))"
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
    source: CompetitionPublicationSource
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

func competitionAwardDateText(
    _ date: Date,
    timeZoneIdentifier: String
) -> String {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: timeZoneIdentifier)
    formatter.dateFormat = "MMM d, yyyy"
    return formatter.string(from: date)
}

func competitionAwardEarnedText(
    _ date: Date,
    timeZoneIdentifier: String
) -> String {
    "Earned \(competitionAwardDateText(date, timeZoneIdentifier: timeZoneIdentifier))"
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
