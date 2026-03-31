import ComposableArchitecture
import SwiftUI

struct MainTabView: View {
    @Bindable var store: StoreOf<MainTabFeature>

    var body: some View {
        TabView(selection: $store.selectedTab.sending(\.tabSelected)) {
            NavigationStack {
                VStack {
                    Image(systemName: "figure.run.circle")
                        .font(.system(size: 60))
                        .foregroundStyle(.green)
                    Text("Active Competitions")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .navigationTitle("Compete")
            }
            .tabItem { Label("Compete", systemImage: "figure.run") }
            .tag(MainTabFeature.Tab.compete)

            FriendsView(store: store.scope(state: \.friends, action: \.friends))
                .tabItem { Label("Friends", systemImage: "person.2") }
                .tag(MainTabFeature.Tab.friends)

            NavigationStack {
                VStack {
                    Image(systemName: "trophy.circle")
                        .font(.system(size: 60))
                        .foregroundStyle(.yellow)
                    Text("Badges & Cosmetics")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .navigationTitle("Awards")
            }
            .tabItem { Label("Awards", systemImage: "trophy") }
            .tag(MainTabFeature.Tab.awards)

            NavigationStack {
                VStack {
                    Image(systemName: "person.crop.circle.fill")
                        .font(.system(size: 60))
                        .foregroundStyle(.purple)
                    Text("Your Profile")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .navigationTitle("Profile")
            }
            .tabItem { Label("Profile", systemImage: "person.crop.circle") }
            .tag(MainTabFeature.Tab.profile)
        }
    }
}

#Preview {
    MainTabView(
        store: Store(initialState: MainTabFeature.State()) {
            MainTabFeature()
        }
    )
}
