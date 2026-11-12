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
        // The same client and session as the app's, for alert reactions,
        // sent only while the person it was posted for is still signed in.
        let setReaction = SupabaseCompetitionRemoteAPI
            .live(provider: supabaseClientProvider).setReaction
        CompetitionReactionAlert.send = { recipient, reaction in
            guard supabaseClientProvider.signedInUserID() == recipient else { return }
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
            // `-widgetScenarioDelay 5` lets a test get back to the widget first,
            // so a recording catches the change.
            let delay = UserDefaults.standard.double(forKey: "widgetScenarioDelay")
            Task { @MainActor in
                let background = UIApplication.shared.beginBackgroundTask()
                try? await Task.sleep(for: .seconds(delay))
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
        // Layers, so only the one on top fades. Main never does: it hosts the
        // sheets and UIKit bars, and its state goes nil with the phase.
        ZStack {
            Theme.ground.ignoresSafeArea()
            switch store.phase {
            // One branch, so the wait doesn't restart between these phases.
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
        .onOpenURL { url in
            guard let route = CompetitionRoute(url: url) else { return }
            _ = CompetitionRoutingEnvironment.liveHub.enqueue(route)
        }
    }

    /// Cleaning up after a session that never opened isn't signing out.
    static func progressTitle(_ teardown: AppFeature.TeardownReason?) -> String {
        switch teardown {
        case nil, .restoredWithoutSession, .cancelledAuthentication:
            "Connecting…"
        case .userRequested, .sessionEnded, .accountDeleted, .profileConflict:
            "Signing out…"
        }
    }
}

/// The mark at window centre while something loads. The launch screen shows
/// it there too, and the root and Home draw it off one clock, keyboard or
/// not, so it stays put and in step as one hands over to the next.
struct AppProgressView: View {
    let title: String

    var body: some View {
        LaunchMarkLayer(title: title)
            .background(Theme.ground)
            .ignoresSafeArea()
            // One flat layer: faded in parts, the mark dips over its twin below.
            .compositingGroup()
            .allowsHitTesting(false)
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

    @AppStorage(AppAppearance.storageKey)
    private var appearance = AppAppearance.system

    /// A nil preference doesn't reach an open sheet, so going back to System
    /// here names the iPhone's own setting instead.
    private var colorScheme: ColorScheme {
        appearance.colorScheme
            ?? (UIScreen.main.traitCollection.userInterfaceStyle == .dark ? .dark : .light)
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
        // A sheet sits outside Home's own environment.
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
            friendSettings: friendSettings
        )
#endif
    }
}

// MARK: - Launch

/// When the current wait began. One value, so every loader pulses in step
/// and counts the same two seconds before it says what it is waiting for.
enum LaunchWait {
    static var began: Date?
    private static var loaders = 0

    static func loaderAppeared() {
        loaders += 1
        if began == nil { began = Date() }
    }

    static func loaderDisappeared() {
        loaders -= 1
        // One loader hands over to the next within a fade.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.5))
            if loaders == 0 { began = nil }
        }
    }
}

/// What the launch mark draws at one instant. Seconds run from the start of
/// the wait; `handoff` is when Home's matches arrived on that clock.
struct LaunchMarkFrame: Equatable {
    /// Where on Home the mark lands: on the hero's slash, where it splits
    /// into the two scores, or on the empty state's open-slot mark.
    enum Landing: Equatable { case score, slot }

    /// One pulse: each bar pulls into the slash, then all three grow back out
    /// on the mark's 150 ms step.
    static let period = 1.25
    /// After the hand-off: when Home's numbers and bars may move, and when
    /// the mark is gone.
    static let reveal = 0.28
    static let duration = 0.47

    var growth: [CGFloat] = [1, 1, 1]
    /// 0 at window centre, 1 on the landing.
    var travel: CGFloat = 0
    /// 0 in the mark, 1 flown clear: the bars leftward, the block rightward.
    var barsLeave: CGFloat = 0
    var blockLeave: CGFloat = 0
    var barsOpacity = 1.0
    var blockOpacity = 1.0
    /// The dashed outline the block leaves behind on the empty state.
    var slotOpacity = 0.0

    init(at time: Double, handoff: Double? = nil, landing: Landing? = nil) {
        let elapsed = handoff.map { time - $0 } ?? 0
        for bar in 0..<3 {
            let pulse = Self.pulse(bar, at: min(time, handoff ?? time))
            // Whatever the pulse was doing, the bars are whole 150 ms in.
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
            // Nowhere to land: the mark fades where it stands.
            barsOpacity = 1 - Self.unit(elapsed, over: 0.2)
            blockOpacity = barsOpacity
        }
    }

    /// One bar's length while waiting.
    static func pulse(_ bar: Int, at time: Double) -> Double {
        guard time >= 0.1 else { return 1 }
        let cycle = (time - 0.1).truncatingRemainder(dividingBy: period)
        let grow = unit(cycle - 0.4 - 0.15 * Double(bar), over: 0.45)
        if grow > 0 { return Motion.growCurve.value(at: grow) }
        return 1 - UnitCurve.easeIn.value(at: unit(cycle - 0.08 * Double(bar), over: 0.2))
    }

    // Stands in for `Motion.settle`, which is a spring and has no clock form.
    private static let settle = UnitCurve.bezier(
        startControlPoint: UnitPoint(x: 0.2, y: 0.9),
        endControlPoint: UnitPoint(x: 0.3, y: 1)
    )

    private static func unit(_ time: Double, over duration: Double) -> Double {
        min(max(time / duration, 0), 1)
    }
}

/// The mark as the launch draws it: a `BrandMark` whose halves can leave.
struct LaunchMark: View {
    /// The launch screen's image is this wide, so the two line up.
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
            // The same outline as Home's open-slot mark.
            MarkPolygon(MarkPolygon.block)
                .stroke(Theme.tertiary, style: StrokeStyle(lineWidth: 2, dash: [5, 4]))
                .opacity(moment.slotOpacity)
        }
        .aspectRatio(1.25, contentMode: .fit)
    }
}

/// The launch mark on its clock, in a layer the size of the window: pulsing
/// at the centre, then flying to `landing` once `handoff` is set. It says
/// what it is waiting for only after two seconds.
private struct LaunchMarkLayer: View {
    let title: String
    var handoff: Date? = nil
    var landing: LaunchLanding? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            TimelineView(.animation) { context in
                let placed = placement(at: context.date, in: proxy)
                ZStack {
                    LaunchMark(moment: placed.moment)
                        .frame(width: placed.width)
                        .position(placed.centre)
                    Text(title)
                        .font(.subheadline)
                        .foregroundStyle(Theme.secondary)
                        .opacity(placed.titleOpacity)
                        .position(
                            x: proxy.size.width / 2,
                            y: proxy.size.height / 2 + LaunchMark.width / 2.5 + 30
                        )
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
                // The mark's slash sits 54% across it, and goes on the scoreboard's.
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

/// Where Home is in the launch hand-off. Anywhere else it is `.done`.
enum LaunchStage {
    /// Laid out under the mark: scores read zero and the bars are unbuilt.
    case waiting
    /// The mark has reached Home: the numbers roll and the bars grow.
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

/// Where the launch mark lands on Home. The first view to offer one wins.
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

/// Home under its loader. When the matches arrive, the mark flies to the
/// landing Home offers and Home's numbers move once it is there. With Reduce
/// Motion the loader fades off Home, and with nowhere to land the mark fades
/// where it stands.
struct LaunchHandoff<Content: View>: View {
    let isLoading: Bool
    let title: String
    let content: Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Nil once Home has the screen to itself.
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
            // Home lays out finished under the mark, still hittable.
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
