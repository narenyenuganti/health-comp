import Foundation

struct BadgeDefinition: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let description: String
    let category: BadgeCategory
    let iconName: String
    let requirement: [String: String]

    enum CodingKeys: String, CodingKey {
        case id, name, description, category, requirement
        case iconName = "icon_name"
    }
}

enum BadgeCategory: String, Codable, Equatable, Sendable {
    case competition
    case streak
    case milestone
}

struct UserBadge: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let userId: UUID
    let badgeId: String
    let earnedAt: Date
    let metadata: [String: String]?

    enum CodingKeys: String, CodingKey {
        case id, metadata
        case userId = "user_id"
        case badgeId = "badge_id"
        case earnedAt = "earned_at"
    }
}

struct CosmeticDefinition: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let category: CosmeticCategory
    let cpCost: Int
    let previewUrl: String?
    let rarity: CosmeticRarity

    enum CodingKeys: String, CodingKey {
        case id, name, category, rarity
        case cpCost = "cp_cost"
        case previewUrl = "preview_url"
    }
}

enum CosmeticCategory: String, Codable, Equatable, Sendable {
    case avatar
    case frame
    case theme
}

enum CosmeticRarity: String, Codable, Equatable, Sendable {
    case common
    case rare
    case epic
    case legendary
}

struct Rivalry: Codable, Equatable, Sendable {
    let userA: UUID
    let userB: UUID
    let totalComps: Int
    let winsA: Int
    let winsB: Int
    let draws: Int
    let currentStreakUser: UUID?
    let currentStreakCount: Int
    let lastCompeted: String?

    enum CodingKeys: String, CodingKey {
        case draws
        case userA = "user_a"
        case userB = "user_b"
        case totalComps = "total_comps"
        case winsA = "wins_a"
        case winsB = "wins_b"
        case currentStreakUser = "current_streak_user"
        case currentStreakCount = "current_streak_count"
        case lastCompeted = "last_competed"
    }
}
