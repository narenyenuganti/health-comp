import XCTest
@testable import HealthComp

final class UserTests: XCTestCase {

    func testUserDecodesFromSupabaseJSON() throws {
        let json = """
        {
            "id": "550e8400-e29b-41d4-a716-446655440000",
            "username": "naren",
            "display_name": "Naren Y",
            "avatar_url": null,
            "bio": "Competing daily",
            "cosmetics": {"avatar": "default", "frame": "none", "theme": "dark"},
            "cp_balance": 250,
            "cp_lifetime": 1200,
            "privacy": {
                "profileVisibility": "public",
                "activityVisibility": "friendsOnly",
                "discoverableByContacts": true
            },
            "created_at": "2026-03-31T12:00:00Z"
        }
        """.data(using: .utf8)!

        let user = try JSONDecoder.supabase.decode(User.self, from: json)

        XCTAssertEqual(user.id, UUID(uuidString: "550e8400-e29b-41d4-a716-446655440000"))
        XCTAssertEqual(user.username, "naren")
        XCTAssertEqual(user.displayName, "Naren Y")
        XCTAssertNil(user.avatarURL)
        XCTAssertEqual(user.bio, "Competing daily")
        XCTAssertEqual(user.cpBalance, 250)
        XCTAssertEqual(user.cosmetics.avatar, "default")
        XCTAssertEqual(user.privacy.profileVisibility, .public)
    }

    func testUserEncodesToSupabaseJSON() throws {
        let user = User(
            id: UUID(uuidString: "550e8400-e29b-41d4-a716-446655440000")!,
            username: "naren",
            displayName: "Naren Y",
            avatarURL: nil,
            bio: nil,
            cosmetics: .default,
            cpBalance: 0,
            cpLifetime: 0,
            privacy: .default,
            createdAt: Date(timeIntervalSince1970: 0)
        )

        let data = try JSONEncoder.supabase.encode(user)
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(dict["username"] as? String, "naren")
        XCTAssertEqual(dict["display_name"] as? String, "Naren Y")
        XCTAssertEqual(dict["cp_balance"] as? Int, 0)
    }

    func testDefaultCosmetics() {
        let cosmetics = User.Cosmetics.default
        XCTAssertEqual(cosmetics.avatar, "default")
        XCTAssertEqual(cosmetics.frame, "none")
        XCTAssertEqual(cosmetics.theme, "dark")
    }

    func testDefaultPrivacy() {
        let privacy = User.Privacy.default
        XCTAssertEqual(privacy.profileVisibility, .public)
        XCTAssertEqual(privacy.activityVisibility, .friendsOnly)
        XCTAssertTrue(privacy.discoverableByContacts)
    }
}
