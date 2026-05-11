import ComposableArchitecture
import SwiftUI

struct FriendsView: View {
    @Bindable var store: StoreOf<FriendsFeature>

    var body: some View {
        NavigationStack {
            List {
                if !store.pendingRequests.isEmpty {
                    Section("Pending Requests") {
                        ForEach(store.pendingRequests, id: \.friendship.id) { item in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(item.friendProfile.displayName)
                                        .font(.headline)
                                    Text("@\(item.friendProfile.username)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Accept") {
                                    store.send(.acceptRequestTapped(item.friendship.id))
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(.green)
                                .controlSize(.small)

                                Button("Decline") {
                                    store.send(.declineRequestTapped(item.friendship.id))
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }
                    }
                }

                Section("Friends") {
                    if store.friends.isEmpty && !store.isLoading {
                        ContentUnavailableView(
                            "No Friends Yet",
                            systemImage: "person.2",
                            description: Text("Search for friends by username to get started.")
                        )
                    } else {
                        ForEach(store.friends, id: \.friendship.id) { item in
                            HStack {
                                Image(systemName: "person.circle.fill")
                                    .font(.title2)
                                    .foregroundStyle(.blue)

                                VStack(alignment: .leading) {
                                    Text(item.friendProfile.displayName)
                                        .font(.headline)
                                    Text("@\(item.friendProfile.username)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    if let activity = store.friendActivity.first(where: { $0.friend.id == item.friendProfile.id }) {
                                        FriendActivityLine(activity: activity)
                                    }
                                }

                                Spacer()

                                Button {
                                    store.send(.challengeFriendTapped(item.friendProfile.id))
                                } label: {
                                    Image(systemName: "trophy.fill")
                                }
                                .accessibilityLabel("Challenge \(item.friendProfile.displayName)")
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }
                    }
                }

                if !store.searchResultUsers.isEmpty {
                    Section("Search Results") {
                        ForEach(store.searchResultUsers) { user in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(user.displayName)
                                        .font(.headline)
                                    Text("@\(user.username)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Add") {
                                    store.send(.sendRequestTapped(user.id))
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                            }
                        }
                    }
                }

                if let competition = store.lastCreatedCompetition {
                    Section("Challenge Status") {
                        Label(
                            "Challenge sent: \(competition.displayModeName)",
                            systemImage: "paperplane.fill"
                        )
                        .foregroundStyle(.green)
                    }
                }
            }
            .navigationTitle("Friends")
            .searchable(text: $store.searchQuery.sending(\.searchQueryChanged))
            .onSubmit(of: .search) {
                store.send(.searchSubmitted)
            }
            .onAppear {
                store.send(.onAppear)
            }
            .overlay {
                if (store.isLoading && store.friends.isEmpty) || store.isCreatingChallenge {
                    ProgressView()
                }
            }
        }
    }
}

#Preview {
    FriendsView(
        store: Store(initialState: FriendsFeature.State()) {
            FriendsFeature()
        }
    )
}

private struct FriendActivityLine: View {
    let activity: FriendActivitySummary

    var body: some View {
        if let summary = activity.latestRingSummary {
            Label(
                "\(summary.appleActivityScore.points.formatted(.number.precision(.fractionLength(0)))) pts today",
                systemImage: "circle.grid.cross"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        } else {
            Label("No shared activity today", systemImage: "circle.dashed")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
