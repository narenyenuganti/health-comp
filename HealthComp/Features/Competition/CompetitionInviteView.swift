import CompetitionCore
import SwiftUI

struct CompetitionInviteView: View {
    let competition: LocalCompetitionPresentation
    let source: CompetitionPublicationSource
    let isCommandInFlight: Bool
    let send: (CompetitionFeature.Action) -> Void
    @State private var showsDeclineConfirmation = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                faceOff
                invitationCopy
                rulesCard
                actionControls
            }
            .frame(maxWidth: 560)
            .padding(.horizontal, 20)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.ground)
        .navigationTitle(navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .alert(
            "Decline invitation from \(competition.opponentDisplayName)?",
            isPresented: $showsDeclineConfirmation
        ) {
            Button("Keep Invitation", role: .cancel) {}
            Button("Decline Invitation", role: .destructive) {
                send(.declineTapped(competition.id))
            }
        } message: {
            Text("This closes the invitation without starting a competition.")
        }
    }

    // The mark, labeled: your ring bars against their single block.
    private var faceOff: some View {
        VStack(spacing: 8) {
            BrandMark().frame(width: 176)
            ZStack {
                Text("YOU")
                    .foregroundStyle(Theme.you)
                    .position(x: 176 * 0.33, y: 9)
                Text(competition.opponentDisplayName.uppercased())
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                    .frame(maxWidth: 88)
                    .position(x: 176 * 0.71, y: 9)
            }
            .font(.themeLabel)
            .tracking(1.4)
            .frame(width: 176, height: 18)
        }
        .frame(maxWidth: .infinity)
        .accessibilityHidden(true)
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
            Text(directionBody)
                .font(.body)
                .foregroundStyle(Theme.secondary)
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
                    "Starting simulates \(competition.opponentDisplayName) accepting this local invitation."
                )
                .font(.caption)
                .foregroundStyle(Theme.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var rulesCard: some View {
        VStack(spacing: 0) {
            CompetitionRuleRow(icon: .symbol("calendar"), title: "Seven calendar days")
            CompetitionRuleDivider()
            CompetitionRuleRow(
                icon: .rings,
                title: "Up to 600 points each day",
                detail: "1 point for every 1% of each ring"
            )
            CompetitionRuleDivider()
            CompetitionRuleRow(
                icon: .symbol("lock.iphone"),
                title: source == .simulatedFixture
                    ? "Your Activity data stays local"
                    : "Only daily points are shared"
            )
        }
        .padding(.horizontal, 16)
        .themePanel(cornerRadius: 18)
    }

    @ViewBuilder
    private var actionControls: some View {
        if case let .pending(direction, _, _) = competition.lifecycle {
            if source == .remoteParticipants {
                Label(
                    direction == .outgoing
                        ? "Waiting for \(competition.opponentDisplayName) to accept"
                        : "Open the invitation link to review and accept",
                    systemImage: "hourglass"
                )
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Theme.secondary)
                .frame(maxWidth: .infinity, minHeight: 44)
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
                    .accessibilityHint("Accepts the local simulated competition")

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
            "Accept invitation from \(competition.opponentDisplayName)"
        )
        .accessibilityHint("Starts the competition tomorrow.")

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
            "Decline invitation from \(competition.opponentDisplayName)"
        )
        .accessibilityHint("Closes this invitation without starting.")
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

    private var navigationTitle: String {
        direction == .incoming
            ? "Invitation from \(competition.opponentDisplayName)"
            : "Compete with \(competition.opponentDisplayName)"
    }

    private var directionTitle: String {
        competitionInviteTitle(
            direction: direction,
            opponentDisplayName: competition.opponentDisplayName
        )
    }

    private var directionBody: String {
        direction == .incoming
            ? "\(competition.opponentDisplayName) invited you to compare Activity points for seven days."
            : "Start when you are ready. Day 1 begins on the next competition calendar day."
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
                if let detail {
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(Theme.secondary)
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
        ? "Invitation from \(opponentDisplayName)"
        : "Outgoing invitation to \(opponentDisplayName)"
}
