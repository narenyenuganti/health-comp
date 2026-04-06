import Dependencies
import DependenciesMacros
import Foundation
import Supabase

@DependencyClient
struct FriendsClient: Sendable {
    var fetchFriends: @Sendable () async throws -> [FriendWithProfile]
    var fetchPendingRequests: @Sendable () async throws -> [FriendWithProfile]
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
                // Fetch accepted friendships with joined user profile
                let friendships: [Friendship] = try await supabase
                    .from("friendships")
                    .select()
                    .eq("status", value: "accepted")
                    .execute()
                    .value
                return friendships.map { FriendWithProfile(friendship: $0, friendProfile: User(
                    id: $0.requesterId, username: "", displayName: "", avatarURL: nil, bio: nil,
                    cosmetics: .default, cpBalance: 0, cpLifetime: 0, privacy: .default, createdAt: Date()
                )) }
            },
            fetchPendingRequests: {
                let friendships: [Friendship] = try await supabase
                    .from("friendships")
                    .select()
                    .eq("status", value: "pending")
                    .execute()
                    .value
                return friendships.map { FriendWithProfile(friendship: $0, friendProfile: User(
                    id: $0.requesterId, username: "", displayName: "", avatarURL: nil, bio: nil,
                    cosmetics: .default, cpBalance: 0, cpLifetime: 0, privacy: .default, createdAt: Date()
                )) }
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
