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
            VStack(spacing: 24) {
                identityEmblem
                invitationCopy
                rulesCard
                actionControls
            }
            .frame(maxWidth: 560)
            .padding(.horizontal, 20)
            .padding(.vertical, 28)
        }
        .background(Color(.systemGroupedBackground))
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

    private var identityEmblem: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [.indigo, .cyan],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 112, height: 112)
            Image(systemName: "figure.run")
                .font(.system(size: 46, weight: .semibold))
                .foregroundStyle(.white)
        }
        .accessibilityHidden(true)
    }

    private var invitationCopy: some View {
        VStack(spacing: 10) {
            Text(directionTitle)
                .font(.title2.weight(.bold))
                .multilineTextAlignment(.center)
            Text(directionBody)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let disclosure = competitionFixtureDisclosure(
                source: source,
                opponentDisplayName: competition.opponentDisplayName
            ) {
                Text(disclosure)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.indigo)
                    .multilineTextAlignment(.center)
            }
            if source == .simulatedFixture, direction == .outgoing {
                Text(
                    "Starting simulates \(competition.opponentDisplayName) accepting this local invitation."
                )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private var rulesCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Seven calendar days", systemImage: "calendar")
            Label("Up to 600 points each day", systemImage: "gauge.with.dots.needle.67percent")
            Label(
                source == .simulatedFixture
                    ? "Your Activity data stays local"
                    : "Only daily points are shared",
                systemImage: "lock.iphone"
            )
        }
        .font(.subheadline.weight(.medium))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(
            .background,
            in: RoundedRectangle(cornerRadius: 20, style: .continuous)
        )
        .shadow(color: .black.opacity(0.05), radius: 10, y: 4)
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
                .foregroundStyle(.secondary)
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
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .disabled(isCommandInFlight)
                    .accessibilityValue(
                        isCommandInFlight ? "Action in progress" : ""
                    )
                    .accessibilityHint("Accepts the local simulated competition")

                case .incoming:
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 12) { incomingButtons }
                        VStack(spacing: 12) { incomingButtons }
                    }
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
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .frame(maxWidth: .infinity, minHeight: 44)
        .disabled(isCommandInFlight)
        .accessibilityLabel(
            "Accept invitation from \(competition.opponentDisplayName)"
        )
        .accessibilityHint("Starts the competition tomorrow.")

        Button("Decline", role: .destructive) {
            showsDeclineConfirmation = true
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .frame(maxWidth: .infinity, minHeight: 44)
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
