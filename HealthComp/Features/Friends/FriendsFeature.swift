import ComposableArchitecture
import Foundation

@Reducer
struct FriendsFeature {
    @ObservableState
    struct State: Equatable {
        var friends: [FriendWithProfile] = []
        var pendingRequests: [FriendWithProfile] = []
        var friendActivity: [FriendActivitySummary] = []
        var searchQuery = ""
        var searchResultUsers: [User] = []
        var isLoading = false
        var isSearching = false
        var isCreatingChallenge = false
        var lastCreatedCompetition: Competition?
        var errorMessage: String?
    }

    enum Action: Equatable, Sendable {
        case onAppear
        case friendsLoaded(Result<[FriendWithProfile], FriendsError>)
        case pendingLoaded(Result<[FriendWithProfile], FriendsError>)
        case friendActivityLoaded(Result<[FriendActivitySummary], FriendsError>)
        case searchQueryChanged(String)
        case searchSubmitted
        case searchResults(Result<[User], FriendsError>)
        case sendRequestTapped(UUID)
        case requestSent(Result<Friendship, FriendsError>)
        case acceptRequestTapped(UUID)
        case requestAccepted(Result<Bool, FriendsError>)
        case declineRequestTapped(UUID)
        case removeFriendTapped(UUID)
        case challengeFriendTapped(UUID)
        case challengeCreated(Result<Competition, FriendsError>)
    }

    @Dependency(\.friendsClient) var friendsClient
    @Dependency(\.competitionClient) var competitionClient

    var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .onAppear:
                state.isLoading = true
                return .run { send in
                    do {
                        let friends = try await friendsClient.fetchFriends()
                        await send(.friendsLoaded(.success(friends)))
                    } catch {
                        await send(.friendsLoaded(.failure(.networkError(error.localizedDescription))))
                    }
                    do {
                        let pending = try await friendsClient.fetchPendingRequests()
                        await send(.pendingLoaded(.success(pending)))
                    } catch {
                        await send(.pendingLoaded(.failure(.networkError(error.localizedDescription))))
                    }
                    do {
                        let activity = try await friendsClient.fetchFriendActivity()
                        await send(.friendActivityLoaded(.success(activity)))
                    } catch {
                        await send(.friendActivityLoaded(.failure(.networkError(error.localizedDescription))))
                    }
                }

            case .friendsLoaded(.success(let friends)):
                state.isLoading = false
                state.friends = friends
                return .none

            case .friendsLoaded(.failure(let error)):
                state.isLoading = false
                state.errorMessage = error.localizedDescription
                return .none

            case .pendingLoaded(.success(let pending)):
                state.pendingRequests = pending
                return .none

            case .pendingLoaded(.failure):
                return .none

            case .friendActivityLoaded(.success(let activity)):
                state.friendActivity = activity
                return .none

            case .friendActivityLoaded(.failure):
                return .none

            case .searchQueryChanged(let query):
                state.searchQuery = query
                return .none

            case .searchSubmitted:
                state.isSearching = true
                let query = state.searchQuery
                return .run { send in
                    do {
                        let users = try await friendsClient.searchByUsername(query)
                        await send(.searchResults(.success(users)))
                    } catch {
                        await send(.searchResults(.failure(.networkError(error.localizedDescription))))
                    }
                }

            case .searchResults(.success(let users)):
                state.isSearching = false
                state.searchResultUsers = users
                return .none

            case .searchResults(.failure):
                state.isSearching = false
                return .none

            case .sendRequestTapped(let userId):
                return .run { send in
                    do {
                        let friendship = try await friendsClient.sendRequest(userId)
                        await send(.requestSent(.success(friendship)))
                    } catch {
                        await send(.requestSent(.failure(.networkError(error.localizedDescription))))
                    }
                }

            case .requestSent:
                return .none

            case .acceptRequestTapped(let friendshipId):
                return .run { send in
                    do {
                        try await friendsClient.acceptRequest(friendshipId)
                        await send(.requestAccepted(.success(true)))
                    } catch {
                        await send(.requestAccepted(.failure(.networkError(error.localizedDescription))))
                    }
                }

            case .requestAccepted(.success):
                // Reload friends and pending
                return .send(.onAppear)

            case .requestAccepted(.failure):
                return .none

            case .declineRequestTapped(let friendshipId):
                return .run { _ in
                    try await friendsClient.declineRequest(friendshipId)
                }

            case .removeFriendTapped(let friendshipId):
                return .run { _ in
                    try await friendsClient.removeFriend(friendshipId)
                }

            case .challengeFriendTapped(let friendId):
                state.isCreatingChallenge = true
                return .run { send in
                    do {
                        let competition = try await competitionClient.createCompetition(
                            .oneVOne,
                            "apple_activity",
                            .appleActivity,
                            AppleActivityScore.durationDays,
                            [friendId]
                        )
                        await send(.challengeCreated(.success(competition)))
                    } catch {
                        await send(.challengeCreated(.failure(.networkError(error.localizedDescription))))
                    }
                }

            case .challengeCreated(.success(let competition)):
                state.isCreatingChallenge = false
                state.lastCreatedCompetition = competition
                return .none

            case .challengeCreated(.failure(let error)):
                state.isCreatingChallenge = false
                state.errorMessage = error.localizedDescription
                return .none
            }
        }
    }
}

enum FriendsError: Error, Equatable, LocalizedError {
    case networkError(String)

    var errorDescription: String? {
        switch self {
        case .networkError(let msg): return msg
        }
    }
}
