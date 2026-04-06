import ComposableArchitecture
import SwiftUI

@main
struct HealthCompApp: App {
    let store = Store(initialState: AppFeature.State()) {
        AppFeature()
    }

    var body: some Scene {
        WindowGroup {
            AppRootView(store: store)
        }
    }
}

struct AppRootView: View {
    let store: StoreOf<AppFeature>

    var body: some View {
        Group {
            switch store.screen {
            case .loading:
                ProgressView("Loading...")

            case .auth:
                if let authStore = store.scope(state: \.auth, action: \.auth) {
                    AuthView(store: authStore)
                }

            case .onboarding:
                if let onboardingStore = store.scope(state: \.onboarding, action: \.onboarding) {
                    OnboardingView(store: onboardingStore)
                }

            case .mainTab:
                if let mainTabStore = store.scope(state: \.mainTab, action: \.mainTab) {
                    MainTabView(store: mainTabStore)
                }
            }
        }
        .onAppear {
            store.send(.onAppear)
        }
    }
}
