import ComposableArchitecture
import SwiftUI

struct AwardsView: View {
    let store: StoreOf<AwardsFeature>

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: Binding(
                    get: { store.selectedTab },
                    set: { store.send(.tabChanged($0)) }
                )) {
                    Text("Badges").tag(AwardsFeature.State.AwardsTab.badges)
                    Text("Shop").tag(AwardsFeature.State.AwardsTab.shop)
                }
                .pickerStyle(.segmented)
                .padding()

                switch store.selectedTab {
                case .badges:
                    badgesGrid
                case .shop:
                    shopList
                }
            }
            .navigationTitle("Awards")
            .onAppear { store.send(.onAppear) }
            .overlay {
                if store.isLoading && store.badgeDefinitions.isEmpty {
                    ProgressView()
                }
            }
        }
    }

    private var badgesGrid: some View {
        ScrollView {
            LazyVGrid(columns: [.init(.adaptive(minimum: 100))], spacing: 16) {
                ForEach(store.badgeDefinitions) { badge in
                    let earned = store.earnedBadgeIds.contains(badge.id)
                    VStack(spacing: 8) {
                        Image(systemName: badge.iconName)
                            .font(.system(size: 36))
                            .foregroundStyle(earned ? .yellow : .gray)
                            .opacity(earned ? 1 : 0.4)

                        Text(badge.name)
                            .font(.caption)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(earned ? .primary : .secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(earned ? Color.yellow.opacity(0.1) : Color.gray.opacity(0.05))
                    .cornerRadius(12)
                }
            }
            .padding()
        }
    }

    private var shopList: some View {
        List(store.cosmeticDefinitions) { cosmetic in
            let owned = store.ownedCosmeticIds.contains(cosmetic.id)
            HStack {
                VStack(alignment: .leading) {
                    Text(cosmetic.name)
                        .font(.headline)
                    HStack {
                        Text(cosmetic.category.rawValue.capitalized)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("•")
                            .foregroundStyle(.secondary)
                        Text(cosmetic.rarity.rawValue.capitalized)
                            .font(.caption)
                            .foregroundStyle(rarityColor(cosmetic.rarity))
                    }
                }
                Spacer()
                if owned {
                    Text("Owned")
                        .font(.caption)
                        .foregroundStyle(.green)
                } else {
                    Button("\(cosmetic.cpCost) CP") {
                        store.send(.purchaseTapped(cosmetic.id, cosmetic.cpCost))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
        }
    }

    private func rarityColor(_ rarity: CosmeticRarity) -> Color {
        switch rarity {
        case .common: return .gray
        case .rare: return .blue
        case .epic: return .purple
        case .legendary: return .orange
        }
    }
}

#Preview {
    AwardsView(
        store: Store(initialState: AwardsFeature.State()) {
            AwardsFeature()
        }
    )
}
