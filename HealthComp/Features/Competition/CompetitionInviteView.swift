import CompetitionCore
import SwiftUI

struct CompetitionInviteView: View {
    let competition: LocalCompetitionPresentation
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
            "Decline invitation from Alex?",
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
            Text("Alex is simulated on this iPhone.")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.indigo)
                .multilineTextAlignment(.center)
            if direction == .outgoing {
                Text("Starting simulates Alex accepting this local invitation.")
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
            Label("Your Activity data stays local", systemImage: "lock.iphone")
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
            switch direction {
            case .outgoing:
                Button {
                    send(.acceptTapped(competition.id))
                } label: {
                    commandLabel("Start with Alex")
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
        .accessibilityLabel("Accept invitation from Alex")
        .accessibilityHint("Starts the competition tomorrow.")

        Button("Decline", role: .destructive) {
            showsDeclineConfirmation = true
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .frame(maxWidth: .infinity, minHeight: 44)
        .disabled(isCommandInFlight)
        .accessibilityLabel("Decline invitation from Alex")
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
        direction == .incoming ? "Invitation from Alex" : "Compete with Alex"
    }

    private var directionTitle: String {
        direction == .incoming
            ? "Invitation from Alex"
            : "Outgoing invitation to Alex"
    }

    private var directionBody: String {
        direction == .incoming
            ? "Alex invited you to compare Activity points for seven days."
            : "Start when you are ready. Day 1 begins on the next competition calendar day."
    }
}
