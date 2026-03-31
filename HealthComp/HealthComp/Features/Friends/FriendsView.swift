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
                                }
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
                if store.isLoading && store.friends.isEmpty {
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
