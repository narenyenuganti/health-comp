import Foundation

enum FriendshipStatus: String, Codable, Equatable, Sendable {
    case pending
    case accepted
    case blocked
}

struct Friendship: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let requesterId: UUID
    let receiverId: UUID
    var status: FriendshipStatus
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case requesterId = "requester_id"
        case receiverId = "receiver_id"
        case status
        case createdAt = "created_at"
    }
}

struct FriendWithProfile: Codable, Equatable, Sendable {
    let friendship: Friendship
    let friendProfile: User

    enum CodingKeys: String, CodingKey {
        case friendship
        case friendProfile = "friend_profile"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let nested = try? container.decode(Friendship.self, forKey: .friendship) {
            friendship = nested
        } else {
            friendship = try Friendship(from: decoder)
        }
        friendProfile = try container.decode(User.self, forKey: .friendProfile)
    }

    init(friendship: Friendship, friendProfile: User) {
        self.friendship = friendship
        self.friendProfile = friendProfile
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(friendship, forKey: .friendship)
        try container.encode(friendProfile, forKey: .friendProfile)
    }
}
