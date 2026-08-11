import CompetitionCore
import SwiftUI

struct CompetitionResultView: View {
    let competition: LocalCompetitionPresentation
    let awards: [LocalCompetitionAward]
    let isCommandInFlight: Bool
    let send: (CompetitionFeature.Action) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isRevealed = false
    @State private var isDeleteConfirmationPresented = false

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                resultHero
                    .opacity(isRevealed ? 1 : 0)
                    .offset(y: isRevealed || reduceMotion ? 0 : 10)

                finalScore
                    .opacity(isRevealed ? 1 : 0)

                if isBestAvailableResult {
                    Label(
                        "Finalized from the best available accepted Activity data after the reconciliation deadline.",
                        systemImage: "info.circle"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                awardPresentation
                    .opacity(isRevealed ? 1 : 0)

                actionControls
            }
            .frame(maxWidth: 560)
            .padding(.horizontal, 16)
            .padding(.vertical, 18)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Result")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if reduceMotion {
                isRevealed = true
            } else {
                withAnimation(.easeOut(duration: 0.28)) {
                    isRevealed = true
                }
            }
        }
    }

    private var resultHero: some View {
        VStack(spacing: 14) {
            HealthCompAwardEmblem(outcome: outcome)
                .frame(width: 150, height: 150)
                .accessibilityHidden(true)
            Text(resultTitle)
                .font(.largeTitle.weight(.bold))
                .multilineTextAlignment(.center)
            Text(resultSubtitle)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    private var finalScore: some View {
        VStack(spacing: 16) {
            Text("Final score")
                .font(.headline)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 24) { finalScoreOwners }
                VStack(spacing: 18) { finalScoreOwners }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(20)
        .background(
            .background,
            in: RoundedRectangle(cornerRadius: 24, style: .continuous)
        )
        .shadow(color: .black.opacity(0.06), radius: 12, y: 5)
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("competition.result")
        .accessibilityLabel(
            "\(resultTitle). Final score. Naren \(competitionPointsAccessibilityText(competition.userPoints)). Alex \(competitionPointsAccessibilityText(competition.opponentPoints))."
        )
    }

    @ViewBuilder
    private var finalScoreOwners: some View {
        FinalScoreOwner(
            name: competition.ownerDisplayName,
            points: competition.userPoints,
            tint: .mint
        )
        Text("–")
            .font(.title2.weight(.medium))
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)
        FinalScoreOwner(
            name: competition.opponentDisplayName,
            points: competition.opponentPoints,
            tint: .indigo
        )
    }

    private var awardPresentation: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Awards")
                .font(.headline)
                .padding(.horizontal, 4)

            ForEach(visibleAwards) { award in
                HStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(
                                award.kind == .victory
                                    ? Color.orange.opacity(0.18)
                                    : Color.green.opacity(0.16)
                            )
                        Image(
                            systemName: award.kind == .victory
                                ? "trophy.fill"
                                : "checkmark.seal.fill"
                        )
                        .font(.title2)
                        .foregroundStyle(
                            award.kind == .victory ? .orange : .green
                        )
                    }
                    .frame(width: 52, height: 52)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(
                            award.kind == .victory
                                ? "Victory Over Alex"
                                : "Competition Complete"
                        )
                        .font(.headline)
                        Text("Earned in this local seven-day competition")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(
                            competitionAwardEarnedText(
                                award.awardedAt,
                                timeZoneIdentifier: competition.timeZoneIdentifier
                            )
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        if award.kind == .victory {
                            Text(
                                competitionVictoryCountText(
                                    awards.filter {
                                        $0.kind == .victory
                                            && $0.friendDisplayName
                                                == award.friendDisplayName
                                    }.count,
                                    friendDisplayName: award.friendDisplayName
                                )
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(14)
                .frame(minHeight: 76)
                .background(
                    .background,
                    in: RoundedRectangle(cornerRadius: 20, style: .continuous)
                )
                .accessibilityElement(children: .combine)
            }
        }
    }

    private var actionControls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { resultButtons }
            VStack(spacing: 12) { resultButtons }
        }
    }

    @ViewBuilder
    private var resultButtons: some View {
        Button {
            send(.rematchTapped(competition.id))
        } label: {
            commandLabel("Rematch")
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .frame(maxWidth: .infinity, minHeight: 44)
        .disabled(isCommandInFlight)

        if !isArchived {
            Button("Archive") {
                send(.archiveTapped(competition.id))
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .frame(maxWidth: .infinity, minHeight: 44)
            .disabled(isCommandInFlight)
        } else {
            Button("Delete Local Data", role: .destructive) {
                isDeleteConfirmationPresented = true
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .frame(maxWidth: .infinity, minHeight: 44)
            .disabled(isCommandInFlight)
            .confirmationDialog(
                "Delete this competition from this iPhone?",
                isPresented: $isDeleteConfirmationPresented,
                titleVisibility: .visible
            ) {
                Button("Delete Local Data", role: .destructive) {
                    send(.deleteTapped(competition.id))
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(
                    "This permanently removes the local competition journal and its notifications."
                )
            }
        }
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

    private var visibleAwards: [LocalCompetitionAward] {
        let matching = awards.filter { $0.competitionID == competition.id }
        return matching
    }

    private var outcome: CompetitionOutcome {
        competition.terminalResult?.outcome ?? {
            if competition.userPoints > competition.opponentPoints { return .win }
            if competition.userPoints < competition.opponentPoints { return .loss }
            return .tie
        }()
    }

    private var resultTitle: String {
        switch outcome {
        case .win: "You Won"
        case .loss: "Alex Won"
        case .tie: "It’s a Tie"
        }
    }

    private var resultSubtitle: String {
        switch outcome {
        case .win: "Your seven-day Activity total finished ahead."
        case .loss: "Alex’s simulated seven-day total finished ahead."
        case .tie: "Both seven-day totals finished even."
        }
    }

    private var isArchived: Bool {
        if case .archived = competition.lifecycle { return true }
        return false
    }

    private var isBestAvailableResult: Bool {
        competition.terminalResult?.basis == .bestAvailable
    }
}

private struct FinalScoreOwner: View {
    let name: String
    let points: Double
    let tint: Color

    var body: some View {
        VStack(spacing: 5) {
            Text(name)
                .font(.subheadline.weight(.semibold))
            Text(competitionPointsText(points))
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
                .monospacedDigit()
            Text("points")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .foregroundStyle(tint)
        .frame(maxWidth: .infinity)
    }
}

private struct HealthCompAwardEmblem: View {
    let outcome: CompetitionOutcome

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 42, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: emblemColors,
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .shadow(color: emblemColors[0].opacity(0.28), radius: 20, y: 10)

            RoundedRectangle(cornerRadius: 34, style: .continuous)
                .stroke(.white.opacity(0.45), lineWidth: 2)
                .padding(10)

            Image(systemName: emblemSymbol)
                .font(.system(size: 58, weight: .bold))
                .foregroundStyle(.white)
        }
    }

    private var emblemColors: [Color] {
        switch outcome {
        case .win: [.orange, .pink]
        case .loss: [.indigo, .blue]
        case .tie: [.teal, .indigo]
        }
    }

    private var emblemSymbol: String {
        switch outcome {
        case .win: "trophy.fill"
        case .loss: "figure.run"
        case .tie: "equal.circle.fill"
        }
    }
}
