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
                                    Text(competition.modeName.replacingOccurrences(of: "_", with: " ").capitalized)
                                        .font(.headline)
                                    Text("\(competition.type == .oneVOne ? "1v1" : "Group") • \(competition.startDate ?? "") – \(competition.endDate ?? "")")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Accept") {
                                    store.send(.acceptInviteTapped(competition.id))
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(.green)
                                .controlSize(.small)
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
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Image(systemName: "figure.run.circle.fill")
                                        .foregroundStyle(.green)
                                    Text(competition.modeName.replacingOccurrences(of: "_", with: " ").capitalized)
                                        .font(.headline)
                                }

                                HStack {
                                    Label(competition.startDate ?? "", systemImage: "calendar")
                                    Text("→")
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
