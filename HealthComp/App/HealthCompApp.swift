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

struct CompetitionClientFactory: Sendable {
    var make: @Sendable (SupabaseClientProvider) -> CompetitionClient

    init(
        _ make: @escaping @Sendable (SupabaseClientProvider) ->
            CompetitionClient
    ) {
        self.make = make
    }

    static let live = Self { provider in
        CompetitionClient.live(provider: provider)
    }
}

enum HealthCompLiveComposition {
    @MainActor
    static func store(
        supabaseClientProvider: SupabaseClientProvider,
        authenticationClientFactory: AuthenticationClientFactory = .live,
        competitionClientFactory: CompetitionClientFactory = .live
    ) -> StoreOf<AppFeature> {
        let authenticationClient = authenticationClientFactory.make(
            supabaseClientProvider
        )
        let competitionClient = competitionClientFactory.make(
            supabaseClientProvider
        )
        // The same client and session as the app's, for alert reactions.
        CompetitionReactionAlert.send = SupabaseCompetitionRemoteAPI
            .live(provider: supabaseClientProvider).setReaction
        return Store(initialState: AppFeature.State()) {
            AppFeature()
                .dependency(\.authenticationClient, authenticationClient)
                .dependency(\.competitionClient, competitionClient)
        }
    }
}

@main
struct HealthCompApp: App {
    @UIApplicationDelegateAdaptor(HealthCompAppDelegate.self)
    private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    private let observerDeliveryLifecycle =
        HealthKitObserverDeliveryLifecycleBridge.production
#if DEBUG
    private let launchDecision: CompetitionTestLabLaunchDecision
    private let multiUserLaunchDecision:
        MultiUserCompetitionTestLabLaunchDecision
    private let liveStore: StoreOf<AppFeature>?
    let testLabColorScheme: ColorScheme?

    init() {
        self.init(
            arguments: ProcessInfo.processInfo.arguments,
            supabaseClientProvider: .live(),
            authenticationClientFactory: .live,
            competitionClientFactory: .live
        )
    }

    init(
        arguments: [String],
        supabaseClientProvider: SupabaseClientProvider,
        authenticationClientFactory: AuthenticationClientFactory = .live,
        competitionClientFactory: CompetitionClientFactory = .live
    ) {
        Theme.applyNavigationBarAppearance()
        let multiUserDecision = MultiUserCompetitionTestLabLaunchParser
            .decision(arguments: arguments)
        let decision = CompetitionTestLabLaunchParser.decision(
            arguments: arguments
        )
        self.multiUserLaunchDecision = multiUserDecision
        self.launchDecision = decision
        switch multiUserDecision {
        case .configured, .invalid:
            self.liveStore = nil
        case .disabled:
            switch decision {
            case .disabled:
                self.liveStore = HealthCompLiveComposition.store(
                    supabaseClientProvider: supabaseClientProvider,
                    authenticationClientFactory: authenticationClientFactory,
                    competitionClientFactory: competitionClientFactory
                )
            case .configured, .invalid:
                // The fixture and fail-closed branches intentionally construct no
                // live dependency graph, HealthKit source, or production journal.
                self.liveStore = nil
            }
        }
        // Pin fixture rendering instead of relying on an OS appearance override.
        // Ordinary DEBUG launches keep the person's in-app appearance choice.
        if self.liveStore == nil,
           let style = zip(arguments, arguments.dropFirst())
               .first(where: { $0.0 == "-AppleInterfaceStyle" })?.1
        {
            self.testLabColorScheme = AppAppearance(rawValue: style.lowercased())?
                .colorScheme
        } else {
            self.testLabColorScheme = nil
        }
        // Deterministic widget captures. Use with the Test Lab only: it builds
        // no AppFeature store, so no publish or sign-out clear replaces it.
        if arguments.contains("--widget-sample") {
            let url = URL(
                string: "\(CompetitionRoute.customURLScheme)://competition/00000000-0000-0000-0000-000000000005"
            )!
            Task {
                await CompetitionWidgetSnapshotClient.liveValue.write(
                    .sample(now: Date(), url: url), []
                )
            }
        }
        // Every widget state for the UI tests; an unknown name clears the file.
        if let scenario = zip(arguments, arguments.dropFirst())
            .first(where: { $0.0 == "--widget-scenario" })?.1
        {
            Task {
                let client = CompetitionWidgetSnapshotClient.liveValue
                if let snapshot = CompetitionWidgetSnapshot.testLab(scenario, now: Date()) {
                    await client.write(snapshot, [])
                } else {
                    try? await client.clear()
                }
            }
        }
    }
#else
    private let store: StoreOf<AppFeature>

    init() {
#if HEALTHCOMP_STAGING
        let provider = SupabaseClientProvider.live()
            .withStagingScoringOperator(.shared)
#else
        let provider = SupabaseClientProvider.live()
#endif
        self.init(
            supabaseClientProvider: provider,
            authenticationClientFactory: .live,
            competitionClientFactory: .live
        )
    }

    init(
        supabaseClientProvider: SupabaseClientProvider,
        authenticationClientFactory: AuthenticationClientFactory = .live,
        competitionClientFactory: CompetitionClientFactory = .live
    ) {
        Theme.applyNavigationBarAppearance()
        self.store = HealthCompLiveComposition.store(
            supabaseClientProvider: supabaseClientProvider,
            authenticationClientFactory: authenticationClientFactory,
            competitionClientFactory: competitionClientFactory
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
        .onChange(of: scenePhase, initial: true) { _, phase in
#if HEALTHCOMP_STAGING
            if phase != .active {
                StagingScoringOperatorControls.shared.cancelStartedCapture()
                StagingScoringOperatorControls.shared.cancelStartedActivityObservation()
            }
#endif
            observerDeliveryLifecycle.observe(
                phase.healthKitObserverLifecyclePhase
            )
        }
    }

#if DEBUG
    @ViewBuilder
    private var debugRoot: some View {
        switch multiUserLaunchDecision {
        case let .configured(configuration):
            MultiUserCompetitionTestLabRootView(configuration: configuration)
                .preferredColorScheme(testLabColorScheme)
        case let .invalid(message):
            MultiUserCompetitionTestLabConfigurationErrorView(message: message)
        case .disabled:
            switch launchDecision {
            case .disabled:
                if let liveStore {
                    AppRootView(store: liveStore)
                }
            case let .configured(configuration):
                CompetitionTestLabRootView(configuration: configuration)
                    .preferredColorScheme(testLabColorScheme)
            case let .invalid(message):
                CompetitionTestLabConfigurationErrorView(message: message)
            }
        }
    }
#endif
}

private extension ScenePhase {
    var healthKitObserverLifecyclePhase: HealthKitObserverLifecyclePhase {
        if self == .active { return .active }
        if self == .background { return .background }
        return .inactive
    }
}

struct AppRootView: View {
    let store: StoreOf<AppFeature>

    @AppStorage(AppAppearance.storageKey)
    private var appearance = AppAppearance.system

    var body: some View {
        Group {
            switch store.phase {
            case .launching, .bootstrappingProfile:
                AppProgressView(title: "Connecting…")

            case .tearingDown:
                AppProgressView(title: "Signing out…")

            case .signedOut, .settingUpProfile, .launchFailure:
                AccountView(
                    store: store.scope(state: \.account, action: \.account),
                    hasPendingChallenge: store.hasPendingChallenge
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
        .tint(Theme.ink)
        .preferredColorScheme(appearance.colorScheme)
        .task {
            await store.send(.task).finish()
        }
        .onOpenURL { url in
            guard let route = CompetitionRoute(url: url) else { return }
            _ = CompetitionRoutingEnvironment.liveHub.enqueue(route)
        }
    }
}

/// The mark holding still. The root and Home draw the same one at window
/// centre, keyboard or not, so it stays put as one hands over to the other.
struct AppProgressView: View {
    let title: String

    var body: some View {
        VStack(spacing: 20) {
            BrandMark().frame(width: 88)
            ProgressView(title)
                .foregroundStyle(Theme.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.ground)
    }
}

// Account lives behind the Home avatar, so there is no two-item tab bar.
struct AuthenticatedRootView: View {
    let mainStore: StoreOf<MainTabFeature>
    let accountStore: StoreOf<AccountFeature>

    var body: some View {
        MainTabView(
            store: mainStore,
            openAccount: { mainStore.send(.accountPresentationChanged(true)) }
        )
        .sheet(
            isPresented: Binding(
                get: { mainStore.isAccountPresented },
                set: { mainStore.send(.accountPresentationChanged($0)) }
            )
        ) {
            AccountSheet(
                mainStore: mainStore,
                accountStore: accountStore,
                done: { mainStore.send(.accountPresentationChanged(false)) }
            )
        }
    }
}

/// Reads the competition's notification state in its own body, so the
/// open sheet follows it.
private struct AccountSheet: View {
    let mainStore: StoreOf<MainTabFeature>
    let accountStore: StoreOf<AccountFeature>
    let done: () -> Void

    var body: some View {
        NavigationStack {
            accountSettings
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: done)
                }
            }
        }
        .task { mainStore.send(.refreshHealthAccess) }
    }

    private var accountSettings: AccountSettingsView {
        let competition = mainStore.competition
        let competitions = competition.publication?.dashboard.competitions ?? []
        let notifications = AccountNotificationSettings(
            authorization: competition.notificationAuthorizationState,
            isRequestInFlight: competition
                .notificationAuthorizationRequestIsInFlight,
            request: {
                mainStore.send(.competition(.enableNotificationsTapped))
            },
            mutedPeople: AccountMutedPerson.list(
                competitions,
                muted: competition.mutedOpponentIdentities
            ),
            mutesInFlight: competition.muteOpponentIdentitiesInFlight,
            unmute: { mainStore.send(.competition(.muteTapped($0))) },
            choicesChanged: {
                mainStore.send(.competition(.notificationChoicesChanged))
            }
        )
        let health = mainStore.healthAccess.map {
            AccountHealthSettings(
                access: $0,
                isReadFailing: competition.publication?.dashboard.issues
                    .contains(.authorizationUnavailable) == true,
                connect: { mainStore.send(.connectHealthTapped) }
            )
        }
        let liveMatchCount = accountLiveMatchCount(competitions)
        // Challenge links are between real accounts only.
        let challengeLink = mainStore.competition.publication?.source == .remoteParticipants
            ? AccountChallengeLink(
                url: mainStore.competition.challengeLink,
                failed: mainStore.competition.challengeLinkLoadFailed,
                load: { mainStore.send(.competition(.challengeLinkRequested)) },
                isResetting: mainStore.competition.challengeLinkIsResetting,
                resetFailed: mainStore.competition.challengeLinkResetFailed,
                reset: { mainStore.send(.competition(.challengeLinkResetConfirmed)) }
            )
            : nil
        let blockedPeople = mainStore.competition.publication?.source == .remoteParticipants
            ? AccountBlockedPeople(
                people: competition.blockedPeople,
                unblocking: competition.unblocksInFlight,
                unblockFailed: competition.unblockFailed,
                load: { mainStore.send(.competition(.blockedPeopleRequested)) },
                unblock: { mainStore.send(.competition(.unblockTapped($0))) }
            )
            : nil
#if HEALTHCOMP_STAGING
        return AccountSettingsView(
            store: accountStore,
            notifications: notifications,
            health: health,
            liveMatchCount: liveMatchCount,
            challengeLink: challengeLink,
            blockedPeople: blockedPeople,
            refreshCompetition: { mainStore.send(.competition(.pullToRefresh)) }
        )
#else
        return AccountSettingsView(
            store: accountStore,
            notifications: notifications,
            health: health,
            liveMatchCount: liveMatchCount,
            challengeLink: challengeLink,
            blockedPeople: blockedPeople
        )
#endif
    }
}
