import ComposableArchitecture
import Foundation

@Reducer
struct AwardsFeature {
    @ObservableState
    struct State: Equatable {
        var badgeDefinitions: [BadgeDefinition] = []
        var earnedBadgeIds: Set<String> = []
        var cosmeticDefinitions: [CosmeticDefinition] = []
        var ownedCosmeticIds: Set<String> = []
        var isLoading = false
        var selectedTab: AwardsTab = .badges

        enum AwardsTab: String, Equatable, Sendable {
            case badges
            case shop
        }
    }

    struct BadgesPayload: Equatable, Sendable {
        let definitions: [BadgeDefinition]
        let earned: [UserBadge]
    }

    struct CosmeticsPayload: Equatable, Sendable {
        let definitions: [CosmeticDefinition]
        let owned: [String]
    }

    enum Action: Equatable, Sendable {
        case onAppear
        case badgesLoaded(Result<BadgesPayload, AwardsError>)
        case cosmeticsLoaded(Result<CosmeticsPayload, AwardsError>)
        case tabChanged(State.AwardsTab)
        case purchaseTapped(String, Int)
        case purchaseResult(Result<Bool, AwardsError>)
    }

    @Dependency(\.awardsClient) var awardsClient

    var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .onAppear:
                state.isLoading = true
                return .run { send in
                    do {
                        let defs = try await awardsClient.fetchBadgeDefinitions()
                        let earned = try await awardsClient.fetchEarnedBadges()
                        await send(.badgesLoaded(.success(BadgesPayload(definitions: defs, earned: earned))))
                    } catch {
                        await send(.badgesLoaded(.failure(.networkError(error.localizedDescription))))
                    }
                    do {
                        let cosmetics = try await awardsClient.fetchCosmeticDefinitions()
                        let owned = try await awardsClient.fetchOwnedCosmetics()
                        await send(.cosmeticsLoaded(.success(CosmeticsPayload(definitions: cosmetics, owned: owned))))
                    } catch {
                        await send(.cosmeticsLoaded(.failure(.networkError(error.localizedDescription))))
                    }
                }

            case .badgesLoaded(.success(let payload)):
                state.isLoading = false
                state.badgeDefinitions = payload.definitions
                state.earnedBadgeIds = Set(payload.earned.map(\.badgeId))
                return .none

            case .badgesLoaded(.failure):
                state.isLoading = false
                return .none

            case .cosmeticsLoaded(.success(let payload)):
                state.cosmeticDefinitions = payload.definitions
                state.ownedCosmeticIds = Set(payload.owned)
                return .none

            case .cosmeticsLoaded(.failure):
                return .none

            case .tabChanged(let tab):
                state.selectedTab = tab
                return .none

            case .purchaseTapped(let cosmeticId, let cost):
                return .run { send in
                    do {
                        try await awardsClient.purchaseCosmetic(cosmeticId, cost)
                        await send(.purchaseResult(.success(true)))
                    } catch {
                        await send(.purchaseResult(.failure(.networkError(error.localizedDescription))))
                    }
                }

            case .purchaseResult(.success):
                return .send(.onAppear)

            case .purchaseResult(.failure):
                return .none
            }
        }
    }
}

enum AwardsError: Error, Equatable, LocalizedError {
    case networkError(String)

    var errorDescription: String? {
        switch self {
        case .networkError(let msg): return msg
        }
    }
}
