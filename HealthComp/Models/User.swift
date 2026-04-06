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

extension User {
    var profileInitials: String {
        let source = displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? username
            : displayName

        let components = source
            .split(whereSeparator: \.isWhitespace)
            .prefix(2)
            .compactMap { $0.first.map(String.init) }

        if !components.isEmpty {
            return components.joined().uppercased()
        }

        return String(username.prefix(2)).uppercased()
    }

    var profileBioSummary: String {
        guard let bio, !bio.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Add a short bio so friends know what you are training for."
        }
        return bio
    }

    var profileVisibilitySummary: String {
        switch privacy.profileVisibility {
        case .public:
            return "Public"
        case .friendsOnly:
            return "Friends only"
        case .private:
            return "Private"
        }
    }

    var activityVisibilitySummary: String {
        switch privacy.activityVisibility {
        case .friendsOnly:
            return "Friends only"
        case .competitorsOnly:
            return "Competitors only"
        }
    }

    var contactDiscoverySummary: String {
        privacy.discoverableByContacts ? "Visible to contacts" : "Hidden from contacts"
    }

    var avatarSummary: String {
        cosmetics.avatar.replacingOccurrences(of: "_", with: " ").capitalized
    }

    var frameSummary: String {
        cosmetics.frame.replacingOccurrences(of: "_", with: " ").capitalized
    }

    var themeSummary: String {
        cosmetics.theme.replacingOccurrences(of: "_", with: " ").capitalized
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

#if DEBUG
extension User {
    static let debugDemoUser = User(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        username: "demo",
        displayName: "Demo User",
        avatarURL: nil,
        bio: "Local debug bypass user",
        cosmetics: .default,
        cpBalance: 0,
        cpLifetime: 0,
        privacy: .default,
        createdAt: Date(timeIntervalSince1970: 0)
    )
}
#endif
