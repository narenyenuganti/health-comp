import ComposableArchitecture
import SwiftUI

struct AuthenticationClientFactory: Sendable {
    var make: @Sendable (SupabaseClientProvider) -> AuthenticationClient

    init(
        _ make: @escaping @Sendable (SupabaseClientProvider) ->
            AuthenticationClient
    ) {
        self.make = make
    }

    static let live = Self { provider in
        SupabaseAuthenticationClient.live(provider: provider)
    }
}

enum HealthCompLiveComposition {
    @MainActor
    static func store(
        supabaseClientProvider: SupabaseClientProvider,
        authenticationClientFactory: AuthenticationClientFactory = .live
    ) -> StoreOf<AppFeature> {
        let authenticationClient = authenticationClientFactory.make(
            supabaseClientProvider
        )
        return Store(initialState: AppFeature.State()) {
            AppFeature()
                .dependency(\.authenticationClient, authenticationClient)
        }
    }
}

@main
struct HealthCompApp: App {
    @UIApplicationDelegateAdaptor(HealthCompAppDelegate.self)
    private var appDelegate
#if DEBUG
    private let launchDecision: CompetitionTestLabLaunchDecision
    private let liveStore: StoreOf<AppFeature>?

    init() {
        self.init(
            arguments: ProcessInfo.processInfo.arguments,
            supabaseClientProvider: .live(),
            authenticationClientFactory: .live
        )
    }

    init(
        arguments: [String],
        supabaseClientProvider: SupabaseClientProvider,
        authenticationClientFactory: AuthenticationClientFactory = .live
    ) {
        let decision = CompetitionTestLabLaunchParser.decision(
            arguments: arguments
        )
        self.launchDecision = decision
        switch decision {
        case .disabled:
            self.liveStore = HealthCompLiveComposition.store(
                supabaseClientProvider: supabaseClientProvider,
                authenticationClientFactory: authenticationClientFactory
            )
        case .configured, .invalid:
            // The fixture and fail-closed branches intentionally construct no
            // live dependency graph, HealthKit source, or production journal.
            self.liveStore = nil
        }
    }
#else
    private let store: StoreOf<AppFeature>

    init() {
        self.init(
            supabaseClientProvider: .live(),
            authenticationClientFactory: .live
        )
    }

    init(
        supabaseClientProvider: SupabaseClientProvider,
        authenticationClientFactory: AuthenticationClientFactory = .live
    ) {
        self.store = HealthCompLiveComposition.store(
            supabaseClientProvider: supabaseClientProvider,
            authenticationClientFactory: authenticationClientFactory
        )
    }
#endif

    var body: some Scene {
        WindowGroup {
#if DEBUG
            debugRoot
#else
            AppRootView(store: store)
#endif
        }
    }

#if DEBUG
    @ViewBuilder
    private var debugRoot: some View {
        switch launchDecision {
        case .disabled:
            if let liveStore {
                AppRootView(store: liveStore)
            }
        case let .configured(configuration):
            CompetitionTestLabRootView(configuration: configuration)
        case let .invalid(message):
            CompetitionTestLabConfigurationErrorView(message: message)
        }
    }
#endif
}

struct AppRootView: View {
    let store: StoreOf<AppFeature>

    var body: some View {
        Group {
            switch store.phase {
            case .launching, .bootstrappingProfile:
                ProgressView("Connecting…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

            case .signedOut, .settingUpProfile, .launchFailure:
                AccountView(
                    store: store.scope(state: \.account, action: \.account)
                )

            case .authenticated:
                if let mainStore = store.scope(
                    state: \.mainTab,
                    action: \.mainTab
                ) {
                    AuthenticatedRootView(
                        mainStore: mainStore,
                        accountStore: store.scope(
                            state: \.account,
                            action: \.account
                        )
                    )
                }
            }
        }
        .task {
            await store.send(.task).finish()
        }
    }
}

private struct AuthenticatedRootView: View {
    let mainStore: StoreOf<MainTabFeature>
    let accountStore: StoreOf<AccountFeature>

    var body: some View {
        TabView {
            MainTabView(store: mainStore)
                .tabItem {
                    Label("Competition", systemImage: "figure.run")
                }

            NavigationStack {
                AccountView(store: accountStore)
                    .navigationTitle("Account")
                    .navigationBarTitleDisplayMode(.inline)
            }
            .tabItem {
                Label("Account", systemImage: "person.crop.circle")
            }
        }
        .onOpenURL { url in
            guard let route = CompetitionRoute(url: url) else { return }
            _ = CompetitionRoutingEnvironment.liveHub.enqueue(route)
        }
    }
}
