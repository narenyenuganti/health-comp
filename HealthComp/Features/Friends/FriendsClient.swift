import Dependencies
import DependenciesMacros
import Foundation
import Supabase

@DependencyClient
struct FriendsClient: Sendable {
    var fetchFriends: @Sendable () async throws -> [FriendWithProfile]
    var fetchPendingRequests: @Sendable () async throws -> [FriendWithProfile]
    var fetchFriendActivity: @Sendable () async throws -> [FriendActivitySummary]
    var sendRequest: @Sendable (_ receiverId: UUID) async throws -> Friendship
    var acceptRequest: @Sendable (_ friendshipId: UUID) async throws -> Void
    var declineRequest: @Sendable (_ friendshipId: UUID) async throws -> Void
    var removeFriend: @Sendable (_ friendshipId: UUID) async throws -> Void
    var searchByUsername: @Sendable (_ query: String) async throws -> [User]
}

extension FriendsClient: TestDependencyKey {
    static let testValue = FriendsClient()
}

extension DependencyValues {
    var friendsClient: FriendsClient {
        get { self[FriendsClient.self] }
        set { self[FriendsClient.self] = newValue }
    }
}

// MARK: - Live Implementation

extension FriendsClient: DependencyKey {
    static let liveValue: FriendsClient = {
        let supabase = SupabaseService.shared

        return FriendsClient(
            fetchFriends: {
                let currentUserId = try await supabase.auth.session.user.id
                let friendships: [Friendship] = try await supabase
                    .from("friendships")
                    .select()
                    .eq("status", value: "accepted")
                    .execute()
                    .value
                let friendIds = friendships.map { $0.friendId(relativeTo: currentUserId) }
                guard !friendIds.isEmpty else { return [] }

                let users: [User] = try await supabase
                    .from("users")
                    .select()
                    .in("id", values: friendIds.map(\.uuidString))
                    .execute()
                    .value

                return friendships.compactMap { friendship in
                    let friendId = friendship.friendId(relativeTo: currentUserId)
                    guard let user = users.first(where: { $0.id == friendId }) else { return nil }
                    return FriendWithProfile(friendship: friendship, friendProfile: user)
                }
            },
            fetchPendingRequests: {
                let currentUserId = try await supabase.auth.session.user.id
                let friendships: [Friendship] = try await supabase
                    .from("friendships")
                    .select()
                    .eq("status", value: "pending")
                    .eq("receiver_id", value: currentUserId.uuidString)
                    .execute()
                    .value
                guard !friendships.isEmpty else { return [] }

                let users: [User] = try await supabase
                    .from("users")
                    .select()
                    .in("id", values: friendships.map(\.requesterId.uuidString))
                    .execute()
                    .value

                return friendships.compactMap { friendship in
                    guard let user = users.first(where: { $0.id == friendship.requesterId }) else { return nil }
                    return FriendWithProfile(friendship: friendship, friendProfile: user)
                }
            },
            fetchFriendActivity: {
                let currentUserId = try await supabase.auth.session.user.id
                let friendships: [Friendship] = try await supabase
                    .from("friendships")
                    .select()
                    .eq("status", value: "accepted")
                    .execute()
                    .value
                let friendIds = friendships.map { $0.friendId(relativeTo: currentUserId) }
                guard !friendIds.isEmpty else { return [] }

                let users: [User] = try await supabase
                    .from("users")
                    .select()
                    .in("id", values: friendIds.map(\.uuidString))
                    .execute()
                    .value
                let summaries: [ActivityRingSummary] = try await supabase
                    .from("activity_ring_summaries")
                    .select()
                    .in("user_id", values: friendIds.map(\.uuidString))
                    .order("date", ascending: false)
                    .execute()
                    .value

                return users.map { user in
                    FriendActivitySummary(
                        friend: user,
                        latestRingSummary: summaries.first { $0.userId == user.id }
                    )
                }
            },
            sendRequest: { receiverId in
                let userId = try await supabase.auth.session.user.id
                struct Payload: Encodable { let requester_id: UUID; let receiver_id: UUID }
                let friendship: Friendship = try await supabase
                    .from("friendships")
                    .insert(Payload(requester_id: userId, receiver_id: receiverId))
                    .select()
                    .single()
                    .execute()
                    .value
                return friendship
            },
            acceptRequest: { friendshipId in
                try await supabase
                    .from("friendships")
                    .update(["status": "accepted"])
                    .eq("id", value: friendshipId.uuidString)
                    .execute()
            },
            declineRequest: { friendshipId in
                try await supabase
                    .from("friendships")
                    .delete()
                    .eq("id", value: friendshipId.uuidString)
                    .execute()
            },
            removeFriend: { friendshipId in
                try await supabase
                    .from("friendships")
                    .delete()
                    .eq("id", value: friendshipId.uuidString)
                    .execute()
            },
            searchByUsername: { query in
                let users: [User] = try await supabase
                    .from("users")
                    .select()
                    .ilike("username", pattern: "%\(query)%")
                    .limit(20)
                    .execute()
                    .value
                return users
            }
        )
    }()
}
