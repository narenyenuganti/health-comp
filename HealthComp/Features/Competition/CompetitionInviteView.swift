import CompetitionCore
import SwiftUI

struct CompetitionInviteView: View {
    let competition: LocalCompetitionPresentation
    let source: CompetitionPublicationSource
    let isCommandInFlight: Bool
    /// The outgoing challenge's link, when this iPhone has asked for it.
    let link: CompetitionFeature.InviteLinkState?
    let send: (CompetitionFeature.Action) -> Void
    @State private var showsDeclineConfirmation = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.locale) private var locale
    @Environment(\.timeZone) private var timeZone

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                faceOff
                invitationCopy
                CompetitionRulesCard(
                    source: source,
                    opponentName: competition.opponentDisplayName
                )
                actionControls
                if isRemoteOutgoing, dynamicTypeSize.isAccessibilitySize {
                    shareControl
                }
            }
            .frame(maxWidth: 560)
            .padding(.horizontal, 20)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.ground)
        // The link stays in reach; PR 7 adds Cancel Challenge under it.
        .safeAreaInset(edge: .bottom) {
            if isRemoteOutgoing, !dynamicTypeSize.isAccessibilitySize {
                shareControl
                    .frame(maxWidth: 560)
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    .padding(.bottom, 8)
                    .frame(maxWidth: .infinity)
                    .background(Theme.ground)
            }
        }
        .task(id: competition.id) {
            if isRemoteOutgoing, link == nil {
                send(.inviteLinkNeeded(competition.id))
            }
        }
        .navigationTitle(competition.opponentDisplayName)
        .navigationBarTitleDisplayMode(.inline)
        .alert(
            "Decline challenge from \(competition.opponentDisplayName)?",
            isPresented: $showsDeclineConfirmation
        ) {
            Button("Keep Challenge", role: .cancel) {}
            Button("Decline Challenge", role: .destructive) {
                send(.declineTapped(competition.id))
            }
        } message: {
            Text("This closes the challenge without starting a match.")
        }
    }

    // The mark, labeled: your ring bars against their single block.
    private var faceOff: some View {
        CompetitionInvitationFaceOff(opponentDisplayName: competition.opponentDisplayName)
    }

    private var invitationCopy: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(direction == .incoming ? "CHALLENGE RECEIVED" : "CHALLENGE SENT")
                .font(.themeLabel)
                .tracking(1.4)
                .foregroundStyle(Theme.secondary)
            Text(directionTitle)
                .font(.largeTitle.weight(.heavy).width(.condensed))
                .foregroundStyle(Theme.ink)
                .accessibilityAddTraits(.isHeader)
            if isRemoteOutgoing {
                Text(directionBody)
                    .font(.body)
                    .foregroundStyle(Theme.secondary)
                    .accessibilityIdentifier("competition.invite.expiry")
            } else {
                Text(directionBody)
                    .font(.body)
                    .foregroundStyle(Theme.secondary)
            }
            if let disclosure = competitionFixtureDisclosure(
                source: source,
                opponentDisplayName: competition.opponentDisplayName
            ) {
                Text(disclosure)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.ink)
            }
            if source == .simulatedFixture, direction == .outgoing {
                Text(
                    "Starting simulates \(competition.opponentDisplayName) accepting this local challenge."
                )
                .font(.caption)
                .foregroundStyle(Theme.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var actionControls: some View {
        if case let .pending(direction, _, _) = competition.lifecycle {
            if source == .remoteParticipants {
                // The outgoing title already says who you're waiting for.
                if direction == .incoming {
                    Label(
                        "Open the challenge link to review and accept",
                        systemImage: "hourglass"
                    )
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.secondary)
                    .frame(maxWidth: .infinity, minHeight: 44)
                }
            } else {
                switch direction {
                case .outgoing:
                    Button {
                        send(.acceptTapped(competition.id))
                    } label: {
                        commandLabel(
                            "Start with \(competition.opponentDisplayName)"
                        )
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(isCommandInFlight)
                    .accessibilityValue(
                        isCommandInFlight ? "Action in progress" : ""
                    )
                    .accessibilityHint("Accepts the local simulated match")

                case .incoming:
                    VStack(spacing: 6) { incomingButtons }
                }
            }
        }
    }

    @ViewBuilder
    private var incomingButtons: some View {
        Button {
            send(.acceptTapped(competition.id))
        } label: {
            commandLabel("Accept")
        }
        .buttonStyle(PrimaryButtonStyle())
        .disabled(isCommandInFlight)
        .accessibilityLabel(
            "Accept challenge from \(competition.opponentDisplayName)"
        )
        .accessibilityHint("Starts on the next match calendar day.")

        Button(role: .destructive) {
            showsDeclineConfirmation = true
        } label: {
            Text("Decline")
                .font(.headline.width(.condensed))
                .foregroundStyle(Theme.secondary)
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isCommandInFlight)
        .accessibilityLabel(
            "Decline challenge from \(competition.opponentDisplayName)"
        )
        .accessibilityHint("Closes this challenge without starting.")
        .accessibilityValue(
            isCommandInFlight ? "Action in progress" : ""
        )
    }

    @ViewBuilder
    private func commandLabel(_ title: String) -> some View {
        if isCommandInFlight {
            HStack(spacing: 8) {
                ProgressView()
                Text(title)
            }
            .frame(maxWidth: .infinity)
        } else {
            Text(title)
                .frame(maxWidth: .infinity)
        }
    }

    private var direction: InvitationDirection {
        guard case let .pending(direction, _, _) = competition.lifecycle else {
            return .outgoing
        }
        return direction
    }

    private var isRemoteOutgoing: Bool {
        source == .remoteParticipants && direction == .outgoing
    }

    private var directionTitle: String {
        if isRemoteOutgoing {
            return "Waiting for \(competition.opponentDisplayName)"
        }
        return competitionInviteTitle(
            direction: direction,
            opponentDisplayName: competition.opponentDisplayName
        )
    }

    private var directionBody: String {
        let name = competition.opponentDisplayName
        if direction == .incoming {
            return "\(name) challenged you to compare Activity points for seven days."
        }
        guard source == .remoteParticipants else {
            return "Start when you are ready. Day 1 begins on the next match calendar day."
        }
        let dayOne = "If \(name) accepts, Day 1 is the next day."
        guard let expiresAt = competition.pendingExpiresAt else { return dayOne }
        let moment = competitionMomentText(
            expiresAt,
            now: competition.evaluatedAt,
            locale: locale,
            timeZone: timeZone
        )
        return "Expires \(moment). \(dayOne)"
    }

    @ViewBuilder
    private var shareControl: some View {
        switch link {
        case let .ready(shareLink, _)?:
            ShareLink(
                item: competitionShareMessage(
                    senderName: competition.ownerDisplayName,
                    link: shareLink
                ),
                subject: Text("Join my HealthComp match")
            ) {
                Label("Share Link Again", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(PrimaryButtonStyle())
            .accessibilityHint(
                "Opens the system share sheet. The private link is not read aloud."
            )
            .accessibilityIdentifier("competition.invite.share")

        case .failed?:
            VStack(alignment: .leading, spacing: 10) {
                Text("Couldn’t load the link. Check your connection and try again.")
                    .font(.caption)
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Try Again") { send(.inviteLinkNeeded(competition.id)) }
                    .buttonStyle(SecondaryButtonStyle())
                    .accessibilityIdentifier("competition.invite.share-retry")
            }

        case .notOnThisPhone?:
            // Until Cancel Challenge ships, it can only be left to expire.
            Text("The link for this challenge isn’t on this iPhone.")
                .font(.caption)
                .foregroundStyle(Theme.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("competition.invite.link-missing")

        case nil, .loading?:
            Button {} label: {
                HStack(spacing: 8) {
                    ProgressView()
                    Label("Share Link Again", systemImage: "square.and.arrow.up")
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(true)
            .accessibilityValue("Loading")
            .accessibilityIdentifier("competition.invite.share")
        }
    }
}

struct CompetitionInvitationFaceOff: View {
    let opponentDisplayName: String

    var body: some View {
        VStack(spacing: 8) {
            BrandMark().frame(width: 176)
            HStack(alignment: .top, spacing: 16) {
                Text("YOU")
                    .foregroundStyle(Theme.you)
                    .frame(maxWidth: .infinity)
                Text(opponentDisplayName.uppercased())
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity)
            }
            .font(.themeLabel)
            .tracking(1.4)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity)
        .accessibilityHidden(true)
    }
}

/// One line of the challenge rules: calendar, scoring or privacy. Shared by
/// the invitation screen and the claim sheet.
struct CompetitionRuleRow: View {
    enum Icon {
        case symbol(String)
        case rings
    }

    let icon: Icon
    let title: String
    var detail: String?

    var body: some View {
        HStack(spacing: 14) {
            iconView
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail {
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 14)
        .frame(minHeight: 44)
    }

    @ViewBuilder
    private var iconView: some View {
        switch icon {
        case let .symbol(name):
            Image(systemName: name)
                .font(.body.weight(.semibold))
                .foregroundStyle(Theme.ink)
        case .rings:
            VStack(alignment: .leading, spacing: 2) {
                SlantedBar().fill(Theme.move).frame(width: 18, height: 4)
                SlantedBar().fill(Theme.exercise).frame(width: 13, height: 4)
                    .padding(.leading, 3)
                SlantedBar().fill(Theme.stand).frame(width: 16, height: 4)
            }
        }
    }
}

struct CompetitionRuleDivider: View {
    var body: some View {
        Rectangle().fill(Theme.hairline).frame(height: 1)
    }
}

/// The one rules and consent card: the week, scoring, who wins and what the
/// other person sees. Shown on the create, challenge and claim screens and
/// from a match's ••• menu.
struct CompetitionRulesCard: View {
    let source: CompetitionPublicationSource
    var opponentName: String? = nil
    var weekText: String? = nil

    var body: some View {
        VStack(spacing: 0) {
            CompetitionRuleRow(
                icon: .symbol("calendar"),
                title: "Seven days",
                detail: weekText ?? "Day 1 is the day after the challenge is accepted."
            )
            CompetitionRuleDivider()
            CompetitionRuleRow(
                icon: .rings,
                title: "1 point per 1% of each ring",
                detail: "Up to 600 points a day"
            )
            CompetitionRuleDivider()
            CompetitionRuleRow(
                icon: .symbol("trophy"),
                title: "Most points after 7 days wins",
                detail: "Equal totals tie. A day with no data scores 0."
            )
            CompetitionRuleDivider()
            if source == .simulatedFixture {
                CompetitionRuleRow(
                    icon: .symbol("lock.iphone"),
                    title: "Nothing leaves this iPhone",
                    detail: opponentName.map { "\($0) is simulated." }
                )
            } else {
                CompetitionRuleRow(
                    icon: .symbol("lock.iphone"),
                    title: "\(opponentName ?? "The other person") sees your daily points and rounded ring percentages",
                    detail: "Also whether you use Move Time or Roll, why a day has no data, and when your iPhone last updated your scores. Your Health data stays on your iPhone."
                )
            }
        }
        .padding(.horizontal, 16)
        .themePanel(cornerRadius: 18)
    }
}

func competitionFixtureDisclosure(
    source: CompetitionPublicationSource,
    opponentDisplayName: String
) -> String? {
    guard source == .simulatedFixture else { return nil }
    return "\(opponentDisplayName) is simulated on this iPhone."
}

func competitionInviteTitle(
    direction: InvitationDirection,
    opponentDisplayName: String
) -> String {
    direction == .incoming
        ? "Challenge from \(opponentDisplayName)"
        : "Challenge to \(opponentDisplayName)"
}
