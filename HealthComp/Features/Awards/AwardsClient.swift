import Dependencies
import DependenciesMacros
import Foundation
import Supabase

@DependencyClient
struct AwardsClient: Sendable {
    var fetchBadgeDefinitions: @Sendable () async throws -> [BadgeDefinition]
    var fetchEarnedBadges: @Sendable () async throws -> [UserBadge]
    var fetchCosmeticDefinitions: @Sendable () async throws -> [CosmeticDefinition]
    var fetchOwnedCosmetics: @Sendable () async throws -> [String]
    var purchaseCosmetic: @Sendable (_ cosmeticId: String, _ cost: Int) async throws -> Void
}

extension AwardsClient: TestDependencyKey {
    static let testValue = AwardsClient()
}

extension DependencyValues {
    var awardsClient: AwardsClient {
        get { self[AwardsClient.self] }
        set { self[AwardsClient.self] = newValue }
    }
}

extension AwardsClient: DependencyKey {
    static let liveValue: AwardsClient = {
        let supabase = SupabaseService.shared

        return AwardsClient(
            fetchBadgeDefinitions: {
                try await supabase.from("badge_definitions").select().execute().value
            },
            fetchEarnedBadges: {
                let userId = try await supabase.auth.session.user.id
                return try await supabase
                    .from("user_badges")
                    .select()
                    .eq("user_id", value: userId.uuidString)
                    .execute()
                    .value
            },
            fetchCosmeticDefinitions: {
                try await supabase.from("cosmetic_definitions").select().execute().value
            },
            fetchOwnedCosmetics: {
                let userId = try await supabase.auth.session.user.id
                struct OwnedRow: Decodable { let cosmetic_id: String }
                let rows: [OwnedRow] = try await supabase
                    .from("user_cosmetics")
                    .select("cosmetic_id")
                    .eq("user_id", value: userId.uuidString)
                    .execute()
                    .value
                return rows.map(\.cosmetic_id)
            },
            purchaseCosmetic: { cosmeticId, cost in
                let userId = try await supabase.auth.session.user.id

                // Deduct CP from user balance
                let user: User = try await supabase
                    .from("users")
                    .select()
                    .eq("id", value: userId.uuidString)
                    .single()
                    .execute()
                    .value

                guard user.cpBalance >= cost else { return }

                try await supabase
                    .from("users")
                    .update(["cp_balance": user.cpBalance - cost])
                    .eq("id", value: userId.uuidString)
                    .execute()

                // Add to owned
                struct PurchasePayload: Encodable {
                    let user_id: UUID
                    let cosmetic_id: String
                }
                try await supabase
                    .from("user_cosmetics")
                    .insert(PurchasePayload(user_id: userId, cosmetic_id: cosmeticId))
                    .execute()
            }
        )
    }()
}
