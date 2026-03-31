import Foundation

struct User: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var username: String
    var displayName: String
    var avatarURL: URL?
    var bio: String?
    var cosmetics: Cosmetics
    var cpBalance: Int
    var cpLifetime: Int
    var privacy: Privacy
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case username
        case displayName = "display_name"
        case avatarURL = "avatar_url"
        case bio
        case cosmetics
        case cpBalance = "cp_balance"
        case cpLifetime = "cp_lifetime"
        case privacy
        case createdAt = "created_at"
    }
}

// MARK: - Nested Types

extension User {
    struct Cosmetics: Codable, Equatable, Sendable {
        var avatar: String
        var frame: String
        var theme: String

        static let `default` = Cosmetics(avatar: "default", frame: "none", theme: "dark")
    }

    struct Privacy: Codable, Equatable, Sendable {
        var profileVisibility: Visibility
        var activityVisibility: ActivityVisibility
        var discoverableByContacts: Bool

        static let `default` = Privacy(
            profileVisibility: .public,
            activityVisibility: .friendsOnly,
            discoverableByContacts: true
        )

        enum Visibility: String, Codable, Sendable {
            case `public`
            case friendsOnly
            case `private`
        }

        enum ActivityVisibility: String, Codable, Sendable {
            case friendsOnly
            case competitorsOnly
        }
    }
}

// MARK: - JSON Coders (snake_case for Supabase)

extension JSONDecoder {
    static let supabase: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

extension JSONEncoder {
    static let supabase: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}
