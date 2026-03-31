import XCTest
@testable import HealthComp

final class FriendshipTests: XCTestCase {

    func testFriendshipDecodesFromSupabase() throws {
        let json = """
        {
            "id": "550e8400-e29b-41d4-a716-446655440000",
            "requester_id": "660e8400-e29b-41d4-a716-446655440000",
            "receiver_id": "770e8400-e29b-41d4-a716-446655440000",
            "status": "accepted",
            "created_at": "2026-03-31T12:00:00Z"
        }
        """.data(using: .utf8)!

        let friendship = try JSONDecoder.supabase.decode(Friendship.self, from: json)
        XCTAssertEqual(friendship.status, .accepted)
        XCTAssertEqual(friendship.requesterId, UUID(uuidString: "660e8400-e29b-41d4-a716-446655440000"))
        XCTAssertEqual(friendship.receiverId, UUID(uuidString: "770e8400-e29b-41d4-a716-446655440000"))
    }

    func testFriendshipStatusValues() {
        XCTAssertEqual(FriendshipStatus.pending.rawValue, "pending")
        XCTAssertEqual(FriendshipStatus.accepted.rawValue, "accepted")
        XCTAssertEqual(FriendshipStatus.blocked.rawValue, "blocked")
    }

    func testFriendWithProfileDecodes() throws {
        let json = """
        {
            "id": "550e8400-e29b-41d4-a716-446655440000",
            "requester_id": "660e8400-e29b-41d4-a716-446655440000",
            "receiver_id": "770e8400-e29b-41d4-a716-446655440000",
            "status": "accepted",
            "created_at": "2026-03-31T12:00:00Z",
            "friend_profile": {
                "id": "770e8400-e29b-41d4-a716-446655440000",
                "username": "alex",
                "display_name": "Alex",
                "avatar_url": null,
                "bio": null,
                "cosmetics": {"avatar": "default", "frame": "none", "theme": "dark"},
                "cp_balance": 100,
                "cp_lifetime": 500,
                "privacy": {"profileVisibility": "public", "activityVisibility": "friendsOnly", "discoverableByContacts": true},
                "created_at": "2026-03-01T00:00:00Z"
            }
        }
        """.data(using: .utf8)!

        let fw = try JSONDecoder.supabase.decode(FriendWithProfile.self, from: json)
        XCTAssertEqual(fw.friendProfile.username, "alex")
        XCTAssertEqual(fw.friendship.status, .accepted)
    }
}
