import ComposableArchitecture
import SwiftUI

@main
struct HealthCompApp: App {
    @UIApplicationDelegateAdaptor(HealthCompAppDelegate.self)
    private var appDelegate
#if DEBUG
    private let launchDecision: CompetitionTestLabLaunchDecision
    private let liveStore: StoreOf<AppFeature>?

    init() {
        let decision = CompetitionTestLabLaunchParser.decision(
            arguments: ProcessInfo.processInfo.arguments
        )
        self.launchDecision = decision
        switch decision {
        case .disabled:
            self.liveStore = Store(initialState: AppFeature.State()) {
                AppFeature()
            }
        case .configured, .invalid:
            // The fixture and fail-closed branches intentionally construct no
            // live dependency graph, HealthKit source, or production journal.
            self.liveStore = nil
        }
    }
#else
    private let store = Store(initialState: AppFeature.State()) {
        AppFeature()
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
        MainTabView(store: store.scope(state: \.mainTab, action: \.mainTab))
            .onOpenURL { url in
                guard let route = CompetitionRoute(url: url) else { return }
                _ = CompetitionRoutingEnvironment.liveHub.enqueue(route)
            }
    }
}
