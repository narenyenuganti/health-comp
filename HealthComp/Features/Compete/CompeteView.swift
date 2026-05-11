import ComposableArchitecture
import SwiftUI

struct CompeteView: View {
    let store: StoreOf<CompeteFeature>

    var body: some View {
        NavigationStack {
            List {
                if !store.pendingInvites.isEmpty {
                    Section("Pending Invites") {
                        ForEach(store.pendingInvites) { competition in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(competition.displayModeName)
                                        .font(.headline)
                                    Text("\(competition.type == .oneVOne ? "1v1" : "Group") • \(competition.startDate ?? "") – \(competition.endDate ?? "")")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                HStack(spacing: 8) {
                                    Button {
                                        store.send(.declineInviteTapped(competition.id))
                                    } label: {
                                        Image(systemName: "xmark")
                                    }
                                    .accessibilityLabel("Decline \(competition.displayModeName)")
                                    .buttonStyle(.bordered)
                                    .tint(.red)
                                    .controlSize(.small)

                                    Button {
                                        store.send(.acceptInviteTapped(competition.id))
                                    } label: {
                                        Image(systemName: "checkmark")
                                    }
                                    .accessibilityLabel("Accept \(competition.displayModeName)")
                                    .buttonStyle(.borderedProminent)
                                    .tint(.green)
                                    .controlSize(.small)
                                }
                            }
                        }
                    }
                }

                Section("Active Competitions") {
                    if store.activeCompetitions.isEmpty && !store.isLoading {
                        ContentUnavailableView(
                            "No Active Competitions",
                            systemImage: "figure.run",
                            description: Text("Challenge a friend from the Friends tab to get started.")
                        )
                    } else {
                        ForEach(store.activeCompetitions) { competition in
                            Button {
                                store.send(.competitionTapped(competition.id))
                            } label: {
                                CompetitionRow(competition: competition)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                if let competition = store.selectedCompetition {
                    Section("Competition Detail") {
                        CompetitionDetailView(
                            competition: competition,
                            summary: store.selectedSummary,
                            isLoading: store.isDetailLoading
                        )
                    }
                }

                if !store.historyCompetitions.isEmpty {
                    Section("History") {
                        ForEach(store.historyCompetitions) { competition in
                            Button {
                                store.send(.competitionTapped(competition.id))
                            } label: {
                                CompetitionRow(competition: competition)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .navigationTitle("Compete")
            .onAppear {
                store.send(.onAppear)
            }
            .overlay {
                if store.isLoading && store.activeCompetitions.isEmpty {
                    ProgressView()
                }
            }
        }
    }
}

#Preview {
    CompeteView(
        store: Store(initialState: CompeteFeature.State()) {
            CompeteFeature()
        }
    )
}

private struct CompetitionRow: View {
    let competition: Competition

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: competition.scoringFormula.kind == .appleActivity ? "circle.grid.cross.fill" : "figure.run.circle.fill")
                    .foregroundStyle(competition.scoringFormula.kind == .appleActivity ? .pink : .green)
                Text(competition.displayModeName)
                    .font(.headline)
                Spacer()
                Text(competition.status.rawValue.capitalized)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            HStack {
                Label(competition.startDate ?? "", systemImage: "calendar")
                Text("-")
                Text(competition.endDate ?? "")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if let stakes = competition.stakesText {
                Text("Stakes: \(stakes)")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct CompetitionDetailView: View {
    let competition: Competition
    let summary: CompetitionScoreSummary?
    let isLoading: Bool

    var body: some View {
        if isLoading {
            ProgressView()
                .frame(maxWidth: .infinity, alignment: .center)
        } else if let summary {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    ScoreBlock(title: "You", points: summary.currentUserTotal)
                    ScoreBlock(title: "Opponent", points: summary.opponentTotal)
                }

                Label(standingText(summary.standing), systemImage: standingIcon(summary.standing))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(standingColor(summary.standing))

                if let result = summary.finalResult {
                    Label(finalResultText(result), systemImage: finalResultIcon(result))
                        .font(.subheadline.weight(.semibold))
                }

                if !summary.dailyHistory.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Daily Scores")
                            .font(.subheadline.weight(.semibold))

                        ForEach(summary.dailyHistory) { day in
                            HStack {
                                Text(day.date)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text("\(day.currentUserPoints, specifier: "%.0f")")
                                Text("-")
                                    .foregroundStyle(.secondary)
                                Text("\(day.opponentPoints, specifier: "%.0f")")
                            }
                            .font(.caption.monospacedDigit())
                        }
                    }
                }
            }
            .padding(.vertical, 6)
        } else {
            ContentUnavailableView(
                "No Scores Yet",
                systemImage: "chart.bar",
                description: Text(competition.status == .pending ? "Scores appear after the competition starts." : "Daily scores have not synced yet.")
            )
        }
    }

    private func standingText(_ standing: CompetitionStanding) -> String {
        switch standing {
        case .tied:
            return "Tied"
        case .ahead(let points):
            return "Ahead by \(points.formatted(.number.precision(.fractionLength(0))))"
        case .behind(let points):
            return "Behind by \(points.formatted(.number.precision(.fractionLength(0))))"
        }
    }

    private func standingIcon(_ standing: CompetitionStanding) -> String {
        switch standing {
        case .tied:
            return "equal.circle.fill"
        case .ahead:
            return "arrow.up.circle.fill"
        case .behind:
            return "arrow.down.circle.fill"
        }
    }

    private func standingColor(_ standing: CompetitionStanding) -> Color {
        switch standing {
        case .tied:
            return .secondary
        case .ahead:
            return .green
        case .behind:
            return .orange
        }
    }

    private func finalResultText(_ result: CompetitionFinalResult) -> String {
        switch result {
        case .won:
            return "Final Result: Won"
        case .lost:
            return "Final Result: Lost"
        case .tied:
            return "Final Result: Tied"
        }
    }

    private func finalResultIcon(_ result: CompetitionFinalResult) -> String {
        switch result {
        case .won:
            return "trophy.fill"
        case .lost:
            return "flag.checkered"
        case .tied:
            return "equal.circle"
        }
    }
}

private struct ScoreBlock: View {
    let title: String
    let points: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(points.formatted(.number.precision(.fractionLength(0))))
                .font(.title3.weight(.bold).monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
