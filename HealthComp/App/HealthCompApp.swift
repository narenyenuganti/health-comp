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
        let setReaction = SupabaseCompetitionRemoteAPI
            .live(provider: supabaseClientProvider).setReaction
        CompetitionReactionAlert.send = { recipient, reaction in
            guard supabaseClientProvider.signedInUserID() == recipient else {
                throw CancellationError()
            }
            try await setReaction(reaction)
        }
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
                self.liveStore = nil
            }
        }
        if self.liveStore == nil,
           let style = zip(arguments, arguments.dropFirst())
               .first(where: { $0.0 == "-AppleInterfaceStyle" })?.1
        {
            self.testLabColorScheme = AppAppearance(rawValue: style.lowercased())?
                .colorScheme
        } else {
            self.testLabColorScheme = nil
        }
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
        if let scenario = zip(arguments, arguments.dropFirst())
            .first(where: { $0.0 == "--widget-scenario" })?.1
        {
            Task { @MainActor in
                let background = UIApplication.shared.beginBackgroundTask()
                let client = CompetitionWidgetSnapshotClient.liveValue
                if let snapshot = CompetitionWidgetSnapshot.testLab(
                    scenario, now: Date(), scheme: CompetitionRoute.customURLScheme
                ) {
                    await client.write(snapshot, [])
                } else {
                    try? await client.clear()
                }
                UIApplication.shared.endBackgroundTask(background)
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
        ZStack {
            Theme.ground.ignoresSafeArea()
            switch store.phase {
            case .launching, .bootstrappingProfile, .tearingDown:
                AppProgressView(title: Self.progressTitle(store.pendingTeardown?.reason))
                .transition(Motion.appear)
                .zIndex(2)

            case .signedOut, .settingUpProfile, .launchFailure:
                AccountView(
                    store: store.scope(state: \.account, action: \.account),
                    hasPendingChallenge: store.hasPendingChallenge
                )
                .transition(Motion.appear)
                .zIndex(1)

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
                    .transition(.identity)
                }
            }
        }
        .tint(Theme.ink)
        .preferredColorScheme(appearance.colorScheme)
        .task {
            await store.send(.task).finish()
        }
        .task { Sounds.prepare() }
        .onOpenURL { url in
            guard let route = CompetitionRoute(url: url) else { return }
            _ = CompetitionRoutingEnvironment.liveHub.enqueue(route)
        }
    }

    static func progressTitle(_ teardown: AppFeature.TeardownReason?) -> String {
        switch teardown {
        case nil, .restoredWithoutSession, .cancelledAuthentication:
            "Connecting…"
        case .userRequested, .sessionEnded, .accountDeleted, .profileConflict:
            "Signing out…"
        }
    }
}

struct AppProgressView: View {
    let title: String

    var body: some View {
        LaunchMarkLayer(title: title)
            .background(Theme.ground)
            .ignoresSafeArea()
            .compositingGroup()
            .allowsHitTesting(false)
    }
}

struct AuthenticatedRootView: View {
    let mainStore: StoreOf<MainTabFeature>
    let accountStore: StoreOf<AccountFeature>

    @Environment(\.colorScheme) private var systemColorScheme

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
                systemColorScheme: systemColorScheme,
                done: { mainStore.send(.accountPresentationChanged(false)) }
            )
        }
    }
}

private struct AccountSheet: View {
    let mainStore: StoreOf<MainTabFeature>
    let accountStore: StoreOf<AccountFeature>
    let systemColorScheme: ColorScheme
    let done: () -> Void

    @AppStorage(AppAppearance.storageKey)
    private var appearance = AppAppearance.system

    private var colorScheme: ColorScheme {
        appearance.colorScheme ?? systemColorScheme
    }

    var body: some View {
        NavigationStack {
            accountSettings
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: done)
                }
            }
        }
        .preferredColorScheme(colorScheme)
        .task { mainStore.send(.refreshHealthAccess) }
        .environment(\.profilePhotos, mainStore.competition.profilePhotoImages)
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
        let liveMatchCount = accountLiveMatchCount(
            competitions,
            groupMatches: competition.publication?.dashboard.groupMatches ?? []
        )
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
        let friendSettings = competition.publication?.source == .remoteParticipants
            ? AccountFriendSettings(
                state: competition.friendSettings,
                send: { mainStore.send(.competition(.friendSettings($0))) }
            )
            : nil
        let ownPhoto = competition.ownPhoto
        let profilePhoto = competition.publication?.source == .remoteParticipants
            ? AccountProfilePhoto(
                status: ownPhoto.status,
                removedByReview: ownPhoto.removedByReview,
                load: { mainStore.send(.competition(.ownPhotoRequested)) },
                save: { mainStore.send(.competition(.ownPhotoSaveTapped($0))) },
                remove: { mainStore.send(.competition(.ownPhotoRemoveConfirmed)) },
                cropClosed: { mainStore.send(.competition(.ownPhotoCropClosed)) }
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
            profilePhoto: profilePhoto,
            friendSettings: friendSettings,
            requestSleepAccess: { mainStore.send(.competition(.sleepAccessRequested)) },
            refreshCompetition: { mainStore.send(.competition(.pullToRefresh)) }
        )
#else
        return AccountSettingsView(
            store: accountStore,
            notifications: notifications,
            health: health,
            liveMatchCount: liveMatchCount,
            challengeLink: challengeLink,
            blockedPeople: blockedPeople,
            profilePhoto: profilePhoto,
            friendSettings: friendSettings,
            requestSleepAccess: { mainStore.send(.competition(.sleepAccessRequested)) }
        )
#endif
    }
}

enum LaunchWait {
    static var began: Date?
    private static var loaders = 0

    static func loaderAppeared() {
        loaders += 1
        if began == nil { began = Date() }
    }

    static func loaderDisappeared() {
        loaders -= 1
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.5))
            if loaders == 0 { began = nil }
        }
    }
}

struct LaunchMarkFrame: Equatable {
    enum Landing: Equatable { case score, slot }

    static let period = 1.25
    static let reveal = 0.28
    static let duration = 0.47

    var growth: [CGFloat] = [1, 1, 1]
    var travel: CGFloat = 0
    var barsLeave: CGFloat = 0
    var blockLeave: CGFloat = 0
    var barsOpacity = 1.0
    var blockOpacity = 1.0
    var slotOpacity = 0.0

    init(at time: Double, handoff: Double? = nil, landing: Landing? = nil) {
        let elapsed = handoff.map { time - $0 } ?? 0
        for bar in 0..<3 {
            let pulse = Self.pulse(bar, at: min(time, handoff ?? time))
            growth[bar] = handoff == nil ? pulse : min(pulse + max(elapsed, 0) / 0.15, 1)
        }
        guard handoff != nil, elapsed > 0 else { return }
        switch landing {
        case .score:
            travel = Self.settle.value(at: Self.unit(elapsed, over: 0.35))
            barsLeave = UnitCurve.easeIn.value(at: Self.unit(elapsed - 0.12, over: 0.33))
            blockLeave = barsLeave
            barsOpacity = 1 - Self.unit(elapsed - 0.22, over: 0.23)
            blockOpacity = barsOpacity
        case .slot:
            travel = Self.settle.value(at: Self.unit(elapsed, over: 0.4))
            blockLeave = UnitCurve.easeIn.value(at: Self.unit(elapsed - 0.15, over: 0.3))
            blockOpacity = 1 - Self.unit(elapsed - 0.22, over: 0.23)
            slotOpacity = UnitCurve.easeOut.value(at: Self.unit(elapsed - 0.2, over: 0.25))
        case nil:
            barsOpacity = 1 - Self.unit(elapsed, over: 0.2)
            blockOpacity = barsOpacity
        }
    }

    static func pulse(_ bar: Int, at time: Double) -> Double {
        guard time >= 0.1 else { return 1 }
        let cycle = (time - 0.1).truncatingRemainder(dividingBy: period)
        let grow = unit(cycle - 0.4 - 0.15 * Double(bar), over: 0.45)
        if grow > 0 { return Motion.growCurve.value(at: grow) }
        return 1 - UnitCurve.easeIn.value(at: unit(cycle - 0.08 * Double(bar), over: 0.2))
    }

    private static let settle = UnitCurve.bezier(
        startControlPoint: UnitPoint(x: 0.2, y: 0.9),
        endControlPoint: UnitPoint(x: 0.3, y: 1)
    )

    private static func unit(_ time: Double, over duration: Double) -> Double {
        min(max(time / duration, 0), 1)
    }
}

struct LaunchMark: View {
    static let width: CGFloat = 90

    let moment: LaunchMarkFrame

    var body: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { bar in
                MarkPolygon(
                    MarkPolygon.bars[bar],
                    growth: moment.growth[bar],
                    shift: -120 * moment.barsLeave,
                    stretch: 1 + 0.5 * moment.barsLeave
                )
                .fill(MarkPolygon.barColors[bar])
            }
            .opacity(moment.barsOpacity)
            MarkPolygon(
                MarkPolygon.block,
                shift: 120 * moment.blockLeave,
                stretch: 1 + 0.5 * moment.blockLeave
            )
            .fill(Theme.ink)
            .opacity(moment.blockOpacity)
            MarkPolygon(MarkPolygon.block)
                .stroke(Theme.tertiary, style: StrokeStyle(lineWidth: 2, dash: [5, 4]))
                .opacity(moment.slotOpacity)
        }
        .aspectRatio(1.25, contentMode: .fit)
    }
}

private struct LaunchMarkLayer: View {
    let title: String
    var handoff: Date? = nil
    var landing: LaunchLanding? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            TimelineView(.animation(minimumInterval: reduceMotion && handoff == nil ? 0.1 : nil)) { context in
                let placed = placement(at: context.date, in: proxy)
                ZStack {
                    LaunchMark(moment: placed.moment)
                        .frame(width: placed.width)
                        .position(placed.centre)
                    Text(title)
                        .font(.subheadline)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(Theme.secondary)
                        .opacity(placed.titleOpacity)
                        .padding(.horizontal, 24)
                        .padding(.top, proxy.size.height / 2 + LaunchMark.width / 2.5 + 20)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .onAppear(perform: LaunchWait.loaderAppeared)
        .onDisappear(perform: LaunchWait.loaderDisappeared)
    }

    private struct Placement {
        let moment: LaunchMarkFrame
        let centre: CGPoint
        let width: CGFloat
        let titleOpacity: Double
    }

    private func placement(at date: Date, in proxy: GeometryProxy) -> Placement {
        let began = LaunchWait.began ?? date
        let time = date.timeIntervalSince(began)
        let moment = LaunchMarkFrame(
            at: reduceMotion ? 0 : time,
            handoff: handoff.map { $0.timeIntervalSince(began) },
            landing: landing?.kind
        )
        let start = CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2)
        var end = start
        var endWidth = LaunchMark.width
        if let landing {
            let bounds = proxy[landing.bounds]
            switch landing.kind {
            case .score:
                end = CGPoint(x: bounds.midX - 0.04 * LaunchMark.width, y: bounds.midY)
            case .slot:
                end = CGPoint(x: bounds.midX, y: bounds.midY)
                endWidth = bounds.width
            }
        }
        return Placement(
            moment: moment,
            centre: CGPoint(
                x: start.x + (end.x - start.x) * moment.travel,
                y: start.y + (end.y - start.y) * moment.travel
            ),
            width: LaunchMark.width + (endWidth - LaunchMark.width) * moment.travel,
            titleOpacity: handoff == nil ? min(max((time - 2) / 0.2, 0), 1) : 0
        )
    }
}

enum LaunchStage {
    case waiting
    case landed
    case done
}

private struct LaunchStageKey: EnvironmentKey {
    static let defaultValue = LaunchStage.done
}

extension EnvironmentValues {
    var launchStage: LaunchStage {
        get { self[LaunchStageKey.self] }
        set { self[LaunchStageKey.self] = newValue }
    }
}

struct LaunchLanding: Equatable {
    let kind: LaunchMarkFrame.Landing
    let bounds: Anchor<CGRect>
}

private struct LaunchLandingKey: PreferenceKey {
    static let defaultValue: LaunchLanding? = nil

    static func reduce(value: inout LaunchLanding?, nextValue: () -> LaunchLanding?) {
        value = value ?? nextValue()
    }
}

extension View {
    func launchLanding(_ kind: LaunchMarkFrame.Landing) -> some View {
        anchorPreference(key: LaunchLandingKey.self, value: .bounds) {
            LaunchLanding(kind: kind, bounds: $0)
        }
    }
}

struct LaunchHandoff<Content: View>: View {
    let isLoading: Bool
    let title: String
    let content: Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var loader: Loader?
    @State private var hasLanded = false

    private enum Loader: Equatable {
        case waiting
        case handing(Date)

        var handoff: Date? {
            if case let .handing(date) = self { date } else { nil }
        }
    }

    init(isLoading: Bool, title: String, @ViewBuilder content: () -> Content) {
        self.isLoading = isLoading
        self.title = title
        self.content = content()
        _loader = State(initialValue: isLoading ? .waiting : nil)
    }

    var body: some View {
        ZStack {
            Theme.ground.ignoresSafeArea()
            content
                .environment(\.launchStage, stage)
                .opacity(loader == .waiting ? Motion.pendingOpacity : 1)
                .animation(
                    reduceMotion ? Motion.fade : Motion.fade.delay(0.15),
                    value: loader == .waiting
                )
        }
        .overlayPreferenceValue(LaunchLandingKey.self) { landing in
            if let loader {
                LaunchMarkLayer(title: title, handoff: loader.handoff, landing: landing)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .onChange(of: isLoading) { _, isLoading in
            if isLoading {
                loader = .waiting
            } else if loader == .waiting {
                if reduceMotion {
                    withAnimation(Motion.fade) { loader = nil }
                } else {
                    loader = .handing(Date())
                }
            }
        }
        .task(id: loader) {
            hasLanded = false
            guard loader?.handoff != nil else { return }
            try? await Task.sleep(for: .seconds(LaunchMarkFrame.reveal))
            guard !Task.isCancelled else { return }
            hasLanded = true
            try? await Task.sleep(
                for: .seconds(LaunchMarkFrame.duration - LaunchMarkFrame.reveal)
            )
            guard !Task.isCancelled else { return }
            loader = nil
        }
    }

    private var stage: LaunchStage {
        guard loader != nil else { return .done }
        return hasLanded ? .landed : .waiting
    }
}
