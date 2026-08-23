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
    let notificationsMuted: Bool
    let notificationMuteIsInFlight: Bool
    let notificationPreferenceSaveFailed: Bool
    let notificationAuthorization:
        CompetitionNotificationAuthorizationState?
    let notificationOpponentDisplayName: String?
    let notificationAuthorizationRequestIsInFlight: Bool
    let requestNotificationAuthorization: () -> Void
    let toggleNotifications: () -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                sharingHero

                if publication.source == .remoteParticipants {
                    CreateCompetitionView(
                        status: inviteCreationStatus,
                        shareLink: createdInviteLink,
                        timeZoneIdentifier: publication.timeZoneIdentifier,
                        create: createInvite
                    )
                }

                if !publication.dashboard.issues.isEmpty {
                    issueBanner
                }

                competitionSection

                if !publication.dashboard.awards.isEmpty {
                    awardsSection
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Sharing")
        .navigationBarTitleDisplayMode(.large)
    }

    private var sharingHero: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Local Activity", systemImage: "figure.run.circle.fill")
                .font(.title2.weight(.bold))
                .foregroundStyle(.tint)
            Text(heroDescription)
                .font(.body)
                .foregroundStyle(.secondary)
            notificationControls

            if notificationPreferenceSaveFailed {
                Label(
                    "Notification preference could not be saved.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
                .accessibilityIdentifier(
                    "competition.notifications.preference-error"
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(.background, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: .black.opacity(0.06), radius: 12, y: 5)
    }

    private var heroDescription: String {
        switch publication.source {
        case .simulatedFixture:
            "Share a seven-day competition with Alex while your scores stay on this iPhone."
        case .remoteParticipants:
            "Compete privately with real people while raw Health data stays on this iPhone."
        }
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
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .frame(minHeight: 44)
            .disabled(notificationAuthorizationRequestIsInFlight)
            .accessibilityIdentifier("competition.notifications.enable")

        case .denied:
            Label(
                "Competition notifications are disabled in Settings.",
                systemImage: "bell.slash.fill"
            )
            .font(.caption)
            .foregroundStyle(.secondary)

        case .authorized, .provisional, .ephemeral:
            if let notificationOpponentDisplayName {
                Button(action: toggleNotifications) {
                    Label(
                        notificationsMuted
                            ? "Unmute \(notificationOpponentDisplayName) Notifications"
                            : "Mute \(notificationOpponentDisplayName) Notifications",
                        systemImage: notificationsMuted
                            ? "bell.slash.fill"
                            : "bell.fill"
                    )
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .frame(minHeight: 44)
                .disabled(notificationMuteIsInFlight)
                .accessibilityIdentifier("competition.notifications.mute")
                .accessibilityValue(
                    notificationMuteIsInFlight
                        ? "Saving"
                        : (notificationsMuted ? "Muted" : "Not muted")
                )
            }

        case nil:
            EmptyView()
        }
    }

    @ViewBuilder
    private var competitionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("People")
                .font(.headline)
                .padding(.horizontal, 4)

            if publication.dashboard.competitions.isEmpty {
                VStack(spacing: 16) {
                    ContentUnavailableView(
                        "No Competition",
                        systemImage: "person.2.slash",
                        description: Text(emptyStateDescription)
                    )

                    if publication.source == .simulatedFixture,
                       publication.dashboard.hiddenTerminalCompetitionCount > 0 {
                        Button {
                            reinvite()
                        } label: {
                            if isReinviteInFlight {
                                ProgressView()
                                    .frame(maxWidth: .infinity)
                            } else {
                                Text(
                                    "Invite \(LocalCompetitionIdentity.opponentDisplayName) Again"
                                )
                                    .frame(maxWidth: .infinity)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .frame(minHeight: 44)
                        .disabled(isReinviteInFlight)
                        .accessibilityValue(
                            isReinviteInFlight ? "Action in progress" : ""
                        )
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(20)
                .background(
                    .background,
                    in: RoundedRectangle(cornerRadius: 22, style: .continuous)
                )
            } else {
                ForEach(publication.dashboard.competitions) { competition in
                    Button {
                        selectCompetition(competition.id)
                    } label: {
                        CompetitionSharingCard(
                            competition: competition,
                            source: publication.source
                        )
                    }
                    .buttonStyle(CompetitionPressButtonStyle())
                    .accessibilityIdentifier(
                        competitionSharingIdentifier(competition)
                    )
                }
            }
        }
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
            Text("Awards")
                .font(.headline)
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
                        Divider().padding(.leading, 58)
                    }
                }
            }
            .background(
                .background,
                in: RoundedRectangle(cornerRadius: 22, style: .continuous)
            )
            .shadow(color: .black.opacity(0.05), radius: 10, y: 4)
        }
    }

    private var issueBanner: some View {
        Label(
            competitionIssueSummary(publication.dashboard.issues),
            systemImage: "exclamationmark.triangle.fill"
        )
        .font(.subheadline.weight(.medium))
        .foregroundStyle(.primary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            Color.orange.opacity(0.16),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .accessibilityLabel(
            "Competition status. \(competitionIssueSummary(publication.dashboard.issues))"
        )
    }
}

private struct CompetitionSharingCard: View {
    let competition: LocalCompetitionPresentation
    let source: CompetitionPublicationSource
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) {
                avatar
                identity
                Spacer(minLength: 8)
                if competitionShouldShowScores(competition.lifecycle) {
                    trailingScore
                }
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.tertiary)
            }

            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 14) {
                    avatar
                    identity
                    Spacer(minLength: 0)
                }
                HStack {
                    if competitionShouldShowScores(competition.lifecycle) {
                        trailingScore
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
        .background(
            .background,
            in: RoundedRectangle(cornerRadius: 22, style: .continuous)
        )
        .shadow(color: .black.opacity(0.06), radius: 12, y: 5)
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
        .accessibilityHint("Opens this competition")
    }

    private var avatar: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [.indigo, .cyan],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Text(competition.opponentDisplayName.prefix(1).uppercased())
                .font(.headline.weight(.bold))
                .foregroundStyle(.white)
        }
        .frame(width: 48, height: 48)
        .accessibilityHidden(true)
    }

    private var identity: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(competition.opponentDisplayName)
                .font(.headline)
                .foregroundStyle(.primary)
            Text(competitionSharingStatus(competition.lifecycle))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(statusTint)
            if let disclosure = competitionFixtureDisclosure(
                source: source,
                opponentDisplayName: competition.opponentDisplayName
            ) {
                Text(disclosure)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .multilineTextAlignment(.leading)
    }

    private var trailingScore: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(competitionPointsText(competition.userPoints))
                .font(.headline.monospacedDigit())
                .foregroundStyle(.primary)
            Text("to \(competitionPointsText(competition.opponentPoints)) pts")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private var statusTint: Color {
        switch competition.lifecycle {
        case .completed, .archived: .green
        case .tallying: .orange
        case .pending: .indigo
        case .declined, .expired: .secondary
        case .scheduled, .active, .endsToday: .accentColor
        }
    }

    private var accessibilitySummary: String {
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
}

private struct CompetitionAwardDashboardRow: View {
    let award: LocalCompetitionAward
    let victoryCount: Int
    let timeZoneIdentifier: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: award.kind == .victory ? "trophy.fill" : "checkmark.seal.fill")
                .font(.title2)
                .foregroundStyle(award.kind == .victory ? .orange : .green)
                .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 2) {
                Text(
                    award.kind == .victory
                        ? "Victory Over \(award.friendDisplayName)"
                        : "Competition Complete"
                )
                    .font(.subheadline.weight(.semibold))
                Text(
                    competitionAwardEarnedText(
                        award.awardedAt,
                        timeZoneIdentifier: timeZoneIdentifier
                    )
                )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if award.kind == .victory {
                    Text(
                        competitionVictoryCountText(
                            victoryCount,
                            friendDisplayName: award.friendDisplayName
                        )
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
            Text("Competition history")
                .font(.subheadline.weight(.semibold))

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 14) { statistics }
                VStack(alignment: .leading, spacing: 8) { statistics }
            }

            if let latestOwnerVictoryAt = summary.latestOwnerVictoryAt {
                Text(
                    "Latest victory \(competitionAwardDateText(latestOwnerVictoryAt, timeZoneIdentifier: timeZoneIdentifier))"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            Color.indigo.opacity(0.10),
            in: RoundedRectangle(cornerRadius: 20, style: .continuous)
        )
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("competition.rivalry")
    }

    @ViewBuilder
    private var statistics: some View {
        rivalryStatistic("Completed", value: summary.completions)
        rivalryStatistic("Your wins", value: summary.ownerWins)
        rivalryStatistic("Other wins", value: summary.opponentWins)
        rivalryStatistic("Ties", value: summary.ties)
    }

    private func rivalryStatistic(
        _ title: String,
        value: Int
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(String(value))
                .font(.headline.monospacedDigit())
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
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
