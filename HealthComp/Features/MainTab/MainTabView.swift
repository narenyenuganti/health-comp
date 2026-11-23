import CompetitionCore
import ComposableArchitecture
import Foundation
import SwiftUI
import UIKit

struct MainTabView: View {
    let store: StoreOf<MainTabFeature>
    var openAccount: (() -> Void)?

    @Environment(\.scenePhase) private var scenePhase
    @State private var isChallengePresented = false
    @State private var challengeSheetRoutes: [CompetitionHomeRoute] = []
    @AppStorage(CompetitionMotionSeen.storageKey)
    private var motionSeen = CompetitionMotionSeen()
    @AppStorage(CompetitionDismissedChallenges.storageKey)
    private var dismissedChallenges = CompetitionDismissedChallenges()
    @State private var isNewMatchPresented = false
    @State private var newMatchLineup: GroupMatchLineup?
    @State private var opensDuel = false
    @State private var isPracticePresented = false
    @State private var isLogoUpdating = false
    @State private var isTodayRingsPresented = false
    @State private var isTourPresented = false
    @State private var isLaunchSlow = false
    @State private var isVersusPlaying = false
    @State private var replaysVersus = false
    @State private var recapPeriod: CompetitionRecapPeriod?
    @State private var profileActionID = UUID()
    @State private var replayIntroActionID = UUID()

    var body: some View {
        ZStack {
            if let onboarding = store.onboarding {
                PermissionOnboardingView(
                    step: onboarding.step,
                    isRequesting: onboarding.isRequesting,
                    isForChallenge: store.acceptsClaimOnStart,
                    continueTapped: { store.send(.onboardingContinueTapped) },
                    notNowTapped: {}
                )
                .transition(Motion.appear)
                .zIndex(1)
            } else {
                home
                    .transition(.identity)
            }
        }
        .task {
            await store.send(.task).finish()
        }
        .task(id: photoOwners) {
            store.send(.competition(.profilePhotosNeeded(photoOwners)))
        }
        .task(id: store.competition.publication?.source == .remoteParticipants) {
            if store.competition.publication?.source == .remoteParticipants {
                store.send(.competition(.blockedPeopleRequested))
                store.send(.competition(.friends(.requested)))
            }
        }
        .onChange(of: scenePhase) { _, newValue in
            store.send(.scenePhaseChanged(Self.sceneState(newValue)))
            if newValue == .active {
                store.send(.competition(.profilePhotosNeeded(photoOwners)))
                if store.competition.publication?.source == .remoteParticipants {
                    store.send(.competition(.friends(.requested)))
                }
            }
        }
        .onChange(of: isChallengePresented || isNewMatchPresented || isPracticePresented || isVersusPlaying || recapPeriod != nil || isTourPresented) { _, isOpen in
            store.send(.challengeSheetVisibilityChanged(isOpen))
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: Notification.Name.NSSystemTimeZoneDidChange
            )
        ) { _ in
            store.send(.timeZoneChanged)
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .healthCompFriendsPushReceived)
        ) { _ in
            if store.competition.publication?.source == .remoteParticipants {
                store.send(.competition(.friends(.requested)))
            }
        }
        .sheet(isPresented: claimSheetPresented) {
            ClaimCompetitionView(
                liveStatus: store.inviteClaimStatus,
                livePreview: store.inviteClaimPreview,
                ownName: store.competition.ownProfile?.displayName ?? "",
                now: store.inviteClaimPreviewEvaluatedAt ?? Date.now,
                hasQueuedChallenge: store.queuedClaimRoute != nil,
                declineFailed: store.claimDeclineFailed,
                accept: { store.send(.acceptClaimTapped) },
                notNow: { store.send(.notNowClaimTapped) },
                decline: { store.send(.declineClaimConfirmed) },
                block: { store.send(.blockClaimConfirmed) },
                retry: { store.send(.retryClaimTapped) },
                dismiss: { store.send(.dismissClaimStatus) }
            )
        }
        .sheet(item: Binding(
            get: { store.challengeFromLink },
            set: { if $0 == nil { store.send(.dismissChallengeFromLink) } }
        )) { link in
            ChallengeFromLinkView(
                link: link,
                status: store.competition.challengeSheetStatus,
                metrics: Binding(
                    get: { store.competition.inviteMetrics },
                    set: { store.send(.competition(.inviteMetricsChanged($0))) }
                ),
                requestSleepAccess: { store.send(.competition(.sleepAccessRequested)) },
                send: { store.send(.sendChallengeFromLinkTapped) },
                retry: { store.send(.retryChallengeFromLinkTapped) },
                openCompetition: { id in
                    store.send(.dismissChallengeFromLink)
                    store.send(.pathChanged([id]))
                },
                close: { store.send(.dismissChallengeFromLink) }
            )
        }
        .sheet(isPresented: $isNewMatchPresented, onDismiss: {
            newMatchLineup = nil
            if opensDuel { opensDuel = false; isChallengePresented = true }
        }) {
            GroupMatchCreateView(
                store: store.scope(state: \.competition.group, action: \.competition.group),
                people: newMatchPeople,
                lineup: newMatchLineup,
                requestSleepAccess: { store.send(.competition(.sleepAccessRequested)) },
                onDuel: { opensDuel = true; isNewMatchPresented = false }
            )
        }
        .onChange(of: store.friendsRouteCount) { _, _ in
            challengeSheetRoutes = []
            isChallengePresented = false
            isNewMatchPresented = false
            isPracticePresented = false
            recapPeriod = nil
        }
        .onChange(of: isChallengePresented) { _, isPresented in
            if isPresented, store.competition.publication?.source == .remoteParticipants {
                store.send(.competition(.challengeLinkRequested))
            }
        }
        .sensoryFeedback(.success, trigger: isSheetLanding) { old, new in
            old && !new && !store.path.isEmpty
                && store.inviteClaimStatus == .idle && store.challengeFromLink == nil
        }
        .environment(\.profilePhotos, store.competition.profilePhotoImages)
    }

    private var newMatchPeople: [GroupMatchPlayer] {
        GroupMatchPlayer.candidates(
            friends: store.competition.friends.list?.friends ?? [],
            matches: store.competition.publication?.dashboard.competitions ?? [],
            blocked: store.competition.blockedPeople ?? []
        )
    }

    private var photoOwners: [UUID] {
        store.competition.photoOwners(claimSender: store.inviteClaimPreview?.sender.id)
    }

    private var isSheetLanding: Bool {
        if store.inviteClaimStatus == .claiming
            || store.inviteClaimStatus == .waitingForCompetition {
            return true
        }
        guard store.challengeFromLink != nil else { return false }
        return store.competition.challengeSheetStatus == .creating
            || store.competition.challengeSheetStatus.controlPhase == .sent
    }

    private func competitionScreen(_ id: CompetitionID) -> some View {
        let publication = store.competition.publication
        let kind = publication?.dashboard.competitions.first { $0.id == id }
            .map { competitionScreenKind($0, source: publication?.source) }
        return ZStack {
            destination(for: id)
                .id(kind)
                .transition(.opacity)
        }
        .animation(kind == nil || kind == .result ? nil : Motion.fade, value: kind)
        .sensoryFeedback(trigger: kind) { old, new in
            guard new == .underway, case let .invite(waitsOnThem)? = old else { return nil }
            return waitsOnThem ? .impact(weight: .medium) : .success
        }
    }

    private var home: some View {
        NavigationStack(path: homeStack) {
            LaunchHandoff(
                isLoading: store.competition.publication == nil,
                title: "Loading matches…"
            ) {
                if let publication = store.competition.publication {
                    CompetitionSharingView(
                        publication: publication,
                        challengeStatus: store.competition.challengeSheetStatus,
                        senderName: store.competition.ownProfile?.displayName,
                        ownChallengeLink: store.competition.challengeLink,
                        dismissChallenge: {
                            store.send(.competition(.challengeSheetDismissed))
                        },
                        recipientCode: Binding(
                            get: { store.competition.inviteRecipientCode },
                            set: { store.send(.competition(.inviteRecipientCodeChanged($0))) }
                        ),
                        recipient: store.competition.inviteRecipient,
                        recipientStatus: store.competition.inviteRecipientStatus,
                        metrics: Binding(
                            get: { store.competition.inviteMetrics },
                            set: { store.send(.competition(.inviteMetricsChanged($0))) }
                        ),
                        requestSleepAccess: { store.send(.competition(.sleepAccessRequested)) },
                        findRecipient: { store.send(.competition(.findInviteRecipientTapped)) },
                        createInvite: {
                            store.send(.competition(.createInviteTapped))
                        },
                        isChallengePresented: $isChallengePresented,
                        presentsChallengeSheet: false,
                        friends: store.competition.friends.list?.friends ?? [],
                        chooseFriend: { friend in
                            store.send(.competition(.challengeRecipientChosen(.init(
                                AuthenticatedProfile(id: friend.id, displayName: friend.displayName)
                            ))))
                        },
                        selectCompetition: {
                            store.send(.pathChanged([$0]))
                        },
                        openHistory: { store.send(.historyPresentationChanged(true)) },
                        reinvite: {
                            store.send(.competition(.reinviteTapped))
                        },
                        isReinviteInFlight: store.competition
                            .isCommandInFlight(
                                LocalCompetitionIdentity
                                    .bootstrapCompetitionID
                            ),
                        challengeAgain: challengeAgain,
                        archive: { store.send(.competition(.archiveTapped($0))) },
                        commandIDsInFlight: store.competition.commandIDsInFlight,
                        retry: retry,
                        practice: practiceStart(publication),
                        isPracticePresented: $isPracticePresented,
                        refresh: { [store] in
                            await store.send(.competition(.pullToRefresh)).finish()
                        },
                        openRecap: { recapPeriod = $0 },
                        isUpdating: isLogoUpdating
                    )
                    .sheet(isPresented: $isChallengePresented, onDismiss: dismissChallengeSheet) {
                        challengeSheet(publication: publication)
                    }
                    .transition(.identity)
                }
            }
            .task {
                try? await Task.sleep(for: .seconds(2))
                isLaunchSlow = true
            }
            .toolbar { homeToolbar }
            .sheet(isPresented: $isPracticePresented) {
                if let publication = store.competition.publication,
                   let practice = practiceStart(publication) {
                    PracticeMatchSheet(
                        practice: practice,
                        requestSleepAccess: { store.send(.competition(.sleepAccessRequested)) }
                    )
                }
            }
            .sheet(isPresented: $isTodayRingsPresented, onDismiss: { store.send(.todayActivityLoaded(nil)) }) {
                CompetitionTodayRingsSheet(
                    competitions: store.competition.publication?.dashboard.competitions ?? [],
                    activity: store.todayActivity,
                    loadActivity: { await store.send(.todayActivityRequested).finish() }
                )
            }
            .navigationDestination(for: CompetitionHomeRoute.self) { route in
                switch route {
                case .history:
                    if let publication = store.competition.publication {
                        CompetitionHistoryView(publication: publication, openRecap: { recapPeriod = $0 })
                            .toolbarRole(.editor)
                    }
                case .friends:
                    FriendsView(store: store)
                        .toolbarRole(.editor)
                case let .person(identity):
                    if let publication = store.competition.publication {
                        personScreen(identity, publication: publication)
                            .toolbarRole(.editor)
                    }
                case let .profile(identity):
                    if let publication = store.competition.publication {
                        profileScreen(identity, publication: publication)
                            .toolbarRole(.editor)
                    }
                case .ownProfile:
                    if let publication = store.competition.publication {
                        CompetitionOwnProfileView(
                            publication: publication,
                            name: store.competition.ownProfile?.displayName ?? "",
                            sharesCareer: store.competition.sharesCareer,
                            setSharesCareer: { store.send(.competition(.careerSharingChanged($0))) },
                            edit: { store.send(.accountPresentationChanged(true)) }
                        )
                        .toolbarRole(.editor)
                        .task { store.send(.competition(.careerSharingRequested)) }
                    }
                case let .records(identity):
                    if let publication = store.competition.publication {
                        CompetitionRecordsView(publication: publication, opponentIdentity: identity)
                            .toolbarRole(.editor)
                    }
                case .ownBadges:
                    if let publication = store.competition.publication {
                        CompetitionBadgesView(publication: publication) {
                            homeStack.wrappedValue.append(.competition($0))
                        }
                        .toolbarRole(.editor)
                    }
                case .ownRecords:
                    if let publication = store.competition.publication {
                        CompetitionOwnRecordsView(publication: publication)
                            .toolbarRole(.editor)
                    }
                case let .competition(id):
                    competitionScreen(id)
                        .toolbarRole(.editor)
                        .onChange(of: completedResultTitle(id)) { old, title in
                            if old == nil, let title {
                                AccessibilityNotification.Announcement(title).post()
                            }
                        }
                }
            }
        }
        .environment(
            \.openCompetitionProfile,
            OpenCompetitionProfileAction(id: profileActionID) { route in
                homeStack.wrappedValue = CompetitionHomeRoute.opening(route, on: homeStack.wrappedValue)
            }
        )
        .sheet(isPresented: notificationPromptPresented) {
            PermissionOnboardingView(
                step: .notifications,
                isRequesting: store.competition
                    .notificationAuthorizationRequestIsInFlight,
                continueTapped: { store.send(.notificationPromptTurnOnTapped) },
                notNowTapped: { store.send(.notificationPromptNotNowTapped) }
            )
            .presentationBackground(Theme.ground)
        }
        .fullScreenCover(isPresented: $isTourPresented, onDismiss: { store.send(.tourFinished) }) {
            HomeTourView(name: store.competition.ownProfile?.displayName ?? "") {
                isTourPresented = false
            }
        }
        .onChange(of: isTourDue, initial: true) { _, isDue in
            if isDue { isTourPresented = true }
        }
        .competitionRecapDeck($recapPeriod, publication: store.competition.publication) {
            homeStack.wrappedValue = $0
        }
        .competitionVersusIntro(
            matchID: store.path.last,
            publication: store.competition.publication,
            isPlaying: $isVersusPlaying,
            replay: $replaysVersus
        )
    }

    private var homeStack: Binding<[CompetitionHomeRoute]> {
        CompetitionHomeRoute.stack(
            path: navigationPath,
            showsHistory: Binding(
                get: { store.showsHistory },
                set: { store.send(.historyPresentationChanged($0)) }
            ),
            person: Binding(
                get: { store.historyPersonIdentity },
                set: { store.send(.historyPersonChanged($0)) }
            ),
            personPlace: Binding(
                get: { store.personPlace },
                set: { store.send(.personPlaceChanged($0)) }
            ),
            showsFriends: Binding(
                get: { store.showsFriends },
                set: { store.send(.friendsPresentationChanged($0)) }
            )
        )
    }

    private var challengeSheetStack: Binding<[CompetitionHomeRoute]> {
        CompetitionHomeRoute.challengeSheetStack(
            routes: $challengeSheetRoutes,
            isPresented: $isChallengePresented,
            closeFriends: { store.send(.competition(.friends(.closed))) },
            openCompetition: { store.send(.pathChanged([$0])) }
        )
    }

    private func dismissChallengeSheet() {
        let hadFriends = challengeSheetRoutes.contains(.friends)
        challengeSheetRoutes = []
        if hadFriends {
            store.send(.competition(.friends(.closed)))
        }
        store.send(.competition(.challengeSheetDismissed))
    }

    private func popChallengeSheet() {
        guard !challengeSheetStack.wrappedValue.isEmpty else { return }
        challengeSheetStack.wrappedValue.removeLast()
    }

    private func challengeSheet(publication: LocalCompetitionPublication) -> some View {
        NavigationStack(path: challengeSheetStack) {
            CreateCompetitionView(
                status: store.competition.challengeSheetStatus,
                timeZoneIdentifier: publication.timeZoneIdentifier,
                evaluatedAt: publication.evaluatedAt,
                recipientCode: Binding(
                    get: { store.competition.inviteRecipientCode },
                    set: { store.send(.competition(.inviteRecipientCodeChanged($0))) }
                ),
                recipient: store.competition.inviteRecipient,
                recipientStatus: store.competition.inviteRecipientStatus,
                metrics: Binding(
                    get: { store.competition.inviteMetrics },
                    set: { store.send(.competition(.inviteMetricsChanged($0))) }
                ),
                requestSleepAccess: { store.send(.competition(.sleepAccessRequested)) },
                senderName: store.competition.ownProfile?.displayName,
                ownChallengeLink: store.competition.challengeLink,
                friends: store.competition.friends.list?.friends ?? [],
                competitions: publication.dashboard.competitions,
                chooseFriend: { friend in
                    store.send(.competition(.challengeRecipientChosen(.init(
                        AuthenticatedProfile(id: friend.id, displayName: friend.displayName)
                    ))))
                },
                searchPeople: {
                    store.send(.competition(.friends(.searchFocusRequested(true))))
                    challengeSheetRoutes = [.friends]
                },
                practice: practiceStart(publication),
                findRecipient: { store.send(.competition(.findInviteRecipientTapped)) },
                create: { store.send(.competition(.createInviteTapped)) },
                openChallenge: { id in
                    let hadFriends = challengeSheetRoutes.contains(.friends)
                    challengeSheetRoutes = []
                    isChallengePresented = false
                    if hadFriends { store.send(.competition(.friends(.closed))) }
                    store.send(.pathChanged([id]))
                }
            )
            .background {
                DrawerInteractivePop(isEnabled: !challengeSheetRoutes.isEmpty)
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: CompetitionHomeRoute.self) { route in
                switch route {
                case .friends:
                    VStack(spacing: 0) {
                        CompetitionDrawerHeader(title: "Friends", back: popChallengeSheet) {
                            CompetitionDrawerCloseButton { isChallengePresented = false }
                                .accessibilityIdentifier("competition.create.done")
                        }
                        FriendsView(store: store)
                    }
                    .background(Theme.ground)
                    .toolbar(.hidden, for: .navigationBar)
                case let .person(identity):
                    personScreen(
                        identity,
                        publication: publication,
                        inChallengeSheet: true,
                        drawerBack: popChallengeSheet
                    )
                    .toolbar(.hidden, for: .navigationBar)
                case let .profile(identity):
                    profileScreen(
                        identity,
                        publication: publication,
                        inChallengeSheet: true,
                        drawerBack: popChallengeSheet
                    )
                    .toolbar(.hidden, for: .navigationBar)
                case let .records(identity):
                    VStack(spacing: 0) {
                        CompetitionDrawerHeader(title: "Records", back: popChallengeSheet) {
                            CompetitionDrawerCloseButton { isChallengePresented = false }
                                .accessibilityIdentifier("competition.create.done")
                        }
                        CompetitionRecordsView(publication: publication, opponentIdentity: identity)
                    }
                    .background(Theme.ground)
                    .toolbar(.hidden, for: .navigationBar)
                case .history, .ownProfile, .ownBadges, .ownRecords, .competition:
                    EmptyView()
                }
            }
        }
        .tint(Theme.ink)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationBackground(Theme.ground)
        .environment(\.openCompetitionProfile, nil)
    }

    @ViewBuilder
    private func personScreen(
        _ identity: String,
        publication: LocalCompetitionPublication,
        inChallengeSheet: Bool = false,
        drawerBack: (() -> Void)? = nil
    ) -> some View {
        if let id = RemoteCompetitionOpponentIdentity.profileID(identity),
           store.competition.friends.people[id] != nil,
           competitionRivalryWeeks(publication.dashboard.competitions, opponentIdentity: identity).isEmpty {
            profileScreen(
                identity,
                publication: publication,
                inChallengeSheet: inChallengeSheet,
                drawerBack: drawerBack
            )
        } else {
            matchedPersonScreen(
                identity,
                publication: publication,
                inChallengeSheet: inChallengeSheet,
                drawerBack: drawerBack
            )
        }
    }

    @ViewBuilder
    private func profileScreen(
        _ identity: String,
        publication: LocalCompetitionPublication,
        inChallengeSheet: Bool = false,
        drawerBack: (() -> Void)? = nil
    ) -> some View {
        let competitions = publication.dashboard.competitions
        let theirs = competitions.filter { $0.opponentIdentity == identity }
        let id = RemoteCompetitionOpponentIdentity.profileID(identity)
        let name = id.flatMap { store.competition.friends.people[$0]?.displayName }
            ?? theirs.first?.opponentDisplayName
            ?? id.flatMap { id in
                publication.dashboard.groupMatches.flatMap(\.seats).first { $0.profileID == id }?.name
            }
        let rivalry = CompetitionProfileRivalry(
            competitions,
            identity: identity,
            name: name ?? "",
            now: publication.evaluatedAt,
            seen: motionSeen,
            dismissedChallengeIDs: dismissedChallenges.ids
        )
        let isBlocked: Bool? = if let id, publication.source == .remoteParticipants {
            store.competition.blockedPeople.map { $0.contains { $0.id == id } }
        } else {
            false
        }
        let isLedger = !rivalry.weeks.isEmpty && (isBlocked == true || rivalry.belt.isRetired)
        if let id, let name, !isLedger {
            FriendProfileView(
                controls: friendControls(id, displayName: name),
                isBlocked: isBlocked,
                unblock: { store.send(.competition(.unblockTapped(id))) },
                challenge: {
                    if inChallengeSheet {
                        let hadFriends = challengeSheetRoutes.contains(.friends)
                        challengeSheetRoutes = []
                        if hadFriends { store.send(.competition(.friends(.closed))) }
                    }
                    if let latest = rivalry.record?.latest {
                        challengeAgain(latest.id)
                    } else {
                        store.send(.competition(.challengeRecipientChosen(.init(
                            AuthenticatedProfile(id: id, displayName: name)
                        ))))
                        isChallengePresented = true
                    }
                },
                hasPlayed: !theirs.isEmpty,
                rivalry: rivalry,
                career: store.competition.careers[id],
                ownCareer: competitionOwnCareer(competitions).career,
                muteButton: theirs.first.flatMap(muteButton(for:)),
                drawerBack: drawerBack
            )
            .task(id: identity) {
                guard publication.source == .remoteParticipants else { return }
                store.send(.competition(.blockedPeopleRequested))
                store.send(.competition(.careerRequested(id)))
            }
        } else {
            matchedPersonScreen(
                identity,
                publication: publication,
                inChallengeSheet: inChallengeSheet,
                drawerBack: drawerBack
            )
        }
    }

    private func matchedPersonScreen(
        _ identity: String,
        publication: LocalCompetitionPublication,
        inChallengeSheet: Bool = false,
        drawerBack: (() -> Void)? = nil
    ) -> some View {
        let depth = store.personPlace.depth
        let profileID = RemoteCompetitionOpponentIdentity.profileID(identity)
        let isBlocked: Bool? = if let profileID, publication.source == .remoteParticipants {
            store.competition.blockedPeople.map { $0.contains { $0.id == profileID } }
        } else {
            false
        }
        return CompetitionPersonView(
            publication: publication,
            opponentIdentity: identity,
            cameFrom: !inChallengeSheet && depth > 0 && depth <= store.path.count
                ? store.path[depth - 1]
                : nil,
            isBlocked: isBlocked,
            unblock: profileID.map { id in { store.send(.competition(.unblockTapped(id))) } },
            muteButton: publication.dashboard.competitions
                .first { $0.opponentIdentity == identity }
                .flatMap(muteButton(for:)),
            challenge: { id in
                if inChallengeSheet {
                    let hadFriends = challengeSheetRoutes.contains(.friends)
                    challengeSheetRoutes = []
                    if hadFriends { store.send(.competition(.friends(.closed))) }
                }
                challengeAgain(id)
            },
            friend: profileID.flatMap { id in
                guard publication.source == .remoteParticipants,
                      let name = publication.dashboard.competitions
                        .first(where: { $0.opponentIdentity == identity })?.opponentDisplayName
                else { return nil }
                return friendControls(id, displayName: name)
            },
            drawerBack: drawerBack
        )
        .task(id: identity) {
            if publication.source == .remoteParticipants {
                store.send(.competition(.blockedPeopleRequested))
            }
        }
    }

    private func friendControls(_ id: UUID, displayName: String) -> PersonFriendControls {
        let friends = store.competition.friends
        let known = friends.people[id]
        let relationship = known?.relationship ?? (friends.list == nil ? nil : FriendRelationship.none)
        let person = known ?? FriendPerson(
            id: id,
            displayName: displayName,
            username: nil,
            relationship: relationship ?? .none
        )
        return PersonFriendControls(
            person: person,
            relationship: relationship,
            isInFlight: friends.inFlight.contains(id),
            failure: friends.failure(for: id),
            isReported: friends.reported.contains(id),
            change: { store.send(.competition(.friends(.changeTapped(person, $0)))) },
            block: { store.send(.competition(.friends(.blockTapped(person)))) },
            report: { store.send(.competition(.friends(.reportTapped(person, andBlock: $0)))) }
        )
    }

    private func recordLink(
        _ competition: LocalCompetitionPresentation,
        in publication: LocalCompetitionPublication
    ) -> CompetitionRecordLink? {
        competitionRecordLinkRecord(for: competition, in: publication.dashboard.competitions).map { record in
            CompetitionRecordLink(record: record) {
                homeStack.wrappedValue.append(.person(record.opponentIdentity))
            }
        }
    }

    private var notificationPromptPresented: Binding<Bool> {
        Binding(
            get: { store.notificationPrompt == .presented },
            set: { isPresented in
                if !isPresented {
                    store.send(.notificationPromptNotNowTapped)
                }
            }
        )
    }

    @ToolbarContentBuilder
    private var homeToolbar: some ToolbarContent {
        if isToolbarShown {
            ToolbarItem(placement: .topBarLeading) {
                Button(action: updateThenShowRings) {
                    BrandMark(spins: isLogoUpdating).frame(height: 26)
                }
                .accessibilityLabel("Today’s rings")
                .accessibilityIdentifier("home.logo")
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                if store.competition.publication?.source == .remoteParticipants {
                    CompetitionChallengeButton {
                        if GroupMatchRollout.showsFormatPicker { isNewMatchPresented = true } else { isChallengePresented = true }
                    }
                    FriendsToolbarButton(requestCount: store.competition.friends.requestCount) {
                        store.send(.friendsPresentationChanged(true))
                    }
                }
                if let openAccount {
                    Button(action: openAccount) {
                        if let name = store.competition.ownProfile?.displayName, !name.isEmpty {
                            PersonAvatar(
                                name: name,
                                size: 34,
                                isYou: true,
                                initialFont: .headline.width(.condensed)
                            )
                        } else {
                            Image(systemName: "person.fill")
                                .foregroundStyle(Theme.ink)
                                .frame(width: 34, height: 34)
                                .background(Theme.control, in: Circle())
                        }
                    }
                    .accessibilityLabel("Account")
                    .accessibilityIdentifier("app.account")
                }
            }
        }
    }

    private var isTourDue: Bool {
        store.showsTour && store.competition.publication != nil
            && store.inviteClaimStatus == .idle && store.challengeFromLink == nil
            && store.notificationPrompt != .presented
    }

    private var isToolbarShown: Bool {
        store.competition.publication != nil || isLaunchSlow
    }

    private func challengeAgain(_ id: CompetitionID) {
        if store.competition.publication?.source == .remoteParticipants {
            store.send(.competition(.challengeAgainTapped(id)))
            isChallengePresented = true
        } else {
            store.send(.competition(.reinviteTapped))
        }
    }

    private func retry() async {
        await store.send(.competition(.pullToRefresh)).finish()
    }

    private func updateThenShowRings() {
        guard !isLogoUpdating else { return }
        isLogoUpdating = true
        Task {
            let clock = ContinuousClock()
            let lap = clock.now + .seconds(0.75)
            await retry()
            try? await clock.sleep(until: lap)
            isLogoUpdating = false
            isTodayRingsPresented = true
        }
    }

    private var navigationPath: Binding<[CompetitionID]> {
        Binding(
            get: { store.path },
            set: { store.send(.pathChanged($0)) }
        )
    }

    private var claimSheetPresented: Binding<Bool> {
        Binding(
            get: { store.inviteClaimStatus != .idle },
            set: { isPresented in
                guard !isPresented else { return }
                switch store.inviteClaimStatus {
                case .loadingPreview, .ready, .retryable:
                    store.send(.notNowClaimTapped)
                case .unavailable, .wrongAccount, .ownChallenge, .activeMatchExists,
                     .confirmationTimedOut:
                    store.send(.dismissClaimStatus)
                case .idle, .declining, .claiming, .waitingForCompetition:
                    break
                }
            }
        )
    }

    private func completedResultTitle(_ id: CompetitionID) -> String? {
        guard let competition = store.competition.publication?.dashboard.competitions
            .first(where: { $0.id == id }),
            case .completed = competition.lifecycle
        else { return nil }
        return competitionResultTitle(
            outcome: competitionResultOutcome(competition),
            opponentDisplayName: competition.opponentDisplayName
        )
    }

    @ViewBuilder
    private func destination(for id: CompetitionID) -> some View {
        if let match = store.competition.publication?.dashboard.groupMatches.first(
            where: { $0.id == id }
        ) {
            GroupMatchDestination(
                match: match,
                store: store.scope(state: \.competition.group, action: \.competition.group),
                createNewMatch: {
                    newMatchLineup = GroupMatchLineup(match: match)
                    isNewMatchPresented = true
                }
            )
            .environment(
                \.groupMatchReplayIntro,
                CompetitionVersusIntroGate.isEnabled
                    && store.competition.publication.flatMap {
                        groupMatchVersusIntroContent(match, source: $0.source, isReplay: true)
                    } != nil
                    ? GroupMatchReplayIntroAction(id: replayIntroActionID) { replaysVersus = true } : nil
            )
        } else if let publication = store.competition.publication,
           let competition = publication.dashboard.competitions.first(
               where: { $0.id == id }
           ),
           competition.isPractice {
            practiceDestination(competition, publication: publication)
        } else if let publication = store.competition.publication,
           let competition = publication.dashboard.competitions.first(
               where: { $0.id == id }
           ) {
            switch competition.lifecycle {
            case .pending:
                CompetitionInviteView(
                    competition: competition,
                    source: publication.source,
                    isCommandInFlight: store.competition
                        .isCommandInFlight(id),
                    link: store.competition.inviteLinks[id],
                    send: sendCompetitionAction,
                    commandFailed: publication.dashboard.issues.contains(.commandRejected(id)),
                    recordLink: recordLink(competition, in: publication)
                )

            case .scheduled, .active, .endsToday, .tallying:
                CompetitionDetailView(
                    competition: competition,
                    source: publication.source,
                    muteButton: muteButton(for: competition),
                    issue: competitionRowIssue(id, in: publication.dashboard.issues),
                    retry: retry,
                    refresh: { [store] in
                        await Task {
                            await store.send(.competition(.pullToRefresh)).finish()
                        }.value
                    },
                    cancelMatch: publication.source == .remoteParticipants
                        ? CompetitionCancelMatch(
                            isInFlight: store.competition.isCommandInFlight(id),
                            failed: publication.dashboard.issues.contains(.commandRejected(id)),
                            cancel: { store.send(.competition(.cancelTapped(id))) }
                        )
                        : nil,
                    nudge: publication.source == .remoteParticipants
                        ? CompetitionNudge(
                            status: store.competition.nudges[id],
                            send: { store.send(.competition(.nudgeTapped(id))) }
                        )
                        : nil,
                    reactions: reactionControl(id, source: publication.source),
                    reportPhoto: competition.opponentProfileID.map { owner in
                        CompetitionReportPhoto(
                            isReported: store.competition.reportedPhotoOwners.contains(owner),
                            isInFlight: store.competition.photoReportsInFlight.contains(owner),
                            report: { store.send(.competition(.photoReportConfirmed(owner))) }
                        )
                    },
                    recordLink: recordLink(competition, in: publication),
                    replayIntro: CompetitionVersusIntroGate.isEnabled
                        && competitionVersusIntroContent(competition, in: publication, isReplay: true) != nil
                        ? { replaysVersus = true } : nil
                )

            case .completed, .archived:
                CompetitionResultView(
                    competition: competition,
                    beltEvent: competitionBeltEvent(
                        for: competition,
                        in: publication.dashboard.competitions
                    ),
                    source: publication.source,
                    rematch: store.competition.rematchState(for: competition),
                    isCommandInFlight: store.competition
                        .isCommandInFlight(id),
                    send: sendCompetitionAction,
                    openCompetition: { store.send(.pathChanged(store.path + [$0])) },
                    muteButton: muteButton(for: competition),
                    issue: competitionRowIssue(id, in: publication.dashboard.issues),
                    retry: retry,
                    reactions: reactionControl(id, source: publication.source),
                    personalBest: competitionPersonalBestText(
                        for: competition,
                        in: publication.dashboard.competitions
                    ),
                    recordLink: recordLink(competition, in: publication)
                )

            case .declined, .expired, .cancelled:
                CompetitionClosedChallengeView(
                    competition: competition,
                    canChallengeAgain: publication.source == .simulatedFixture
                        || RemoteCompetitionOpponentIdentity.profileID(
                            competition.opponentIdentity
                        ) != nil,
                    isInFlight: publication.source == .simulatedFixture
                        && store.competition.isCommandInFlight(
                            LocalCompetitionIdentity.bootstrapCompetitionID
                        ),
                    challengeAgain: {
                        store.send(.pathChanged([]))
                        challengeAgain(id)
                    }
                )
            }
        } else if !store.path.contains(id) {
            Theme.ground.ignoresSafeArea()
        } else {
            ContentUnavailableView(
                "Match Unavailable",
                systemImage: "exclamationmark.circle",
                description: Text("Go back to Home to refresh this match.")
            )
        }
    }

    @ViewBuilder
    private func practiceDestination(
        _ competition: LocalCompetitionPresentation,
        publication: LocalCompetitionPublication
    ) -> some View {
        let id = competition.id
        switch competition.lifecycle {
        case .completed, .archived:
            CompetitionResultView(
                competition: competition,
                beltEvent: nil,
                source: .remoteParticipants,
                rematch: .available,
                isCommandInFlight: false,
                send: sendCompetitionAction,
                openCompetition: { store.send(.pathChanged(store.path + [$0])) },
                issue: competitionRowIssue(id, in: publication.dashboard.issues),
                retry: retry,
                challengeSomeone: {
                    store.send(.pathChanged([]))
                    isChallengePresented = true
                }
            )
        default:
            CompetitionDetailView(
                competition: competition,
                source: .simulatedFixture,
                issue: competitionRowIssue(id, in: publication.dashboard.issues),
                retry: retry,
                refresh: { [store] in
                    await Task {
                        await store.send(.competition(.pullToRefresh)).finish()
                    }.value
                },
                endPractice: { store.send(.competition(.deleteTapped(id))) }
            )
        }
    }

    private func practiceStart(
        _ publication: LocalCompetitionPublication
    ) -> CompetitionPracticeStart? {
        guard publication.source == .remoteParticipants else { return nil }
        let shadowRivals = PracticeMatch.shadowRivals(
            competitions: publication.dashboard.competitions,
            groupMatches: publication.dashboard.groupMatches,
            blocked: store.competition.blockedPeople ?? []
        )
        return CompetitionPracticeStart(
            isStarting: store.competition.isCommandInFlight(PracticeMatch.startCommandID),
            failed: publication.dashboard.issues.contains(
                .commandRejected(PracticeMatch.startCommandID)
            ),
            shadowRivals: shadowRivals,
            start: { store.send(.competition(.practiceStartTapped($0))) }
        )
    }

    private func sendCompetitionAction(_ action: CompetitionFeature.Action) {
        store.send(.competition(action))
    }

    private func reactionControl(
        _ id: CompetitionID,
        source: CompetitionPublicationSource
    ) -> CompetitionReactionControl? {
        guard source == .remoteParticipants else { return nil }
        return store.competition.reactionControl(for: id) { store.send(.competition($0)) }
    }

    private func muteButton(
        for competition: LocalCompetitionPresentation
    ) -> CompetitionMuteButton? {
        guard let identity = competitionMuteIdentity(
            competition,
            authorization: store.competition.notificationAuthorizationState
        ) else {
            return nil
        }
        return CompetitionMuteButton(
            opponentName: competition.opponentDisplayName,
            isMuted: store.competition.mutedOpponentIdentities
                .contains(identity),
            isInFlight: store.competition.muteOpponentIdentitiesInFlight
                .contains(identity),
            failure: store.competition.muteSaveFailures[identity]
                .map { $0 ? CompetitionMuteFailure.mute : .unmute }
                ?? (store.competition.mutePreferencesLoadFailed ? .load : nil),
            toggle: { store.send(.competition(.muteTapped(identity))) }
        )
    }

    private static func sceneState(
        _ scenePhase: ScenePhase
    ) -> MainTabFeature.SceneState {
        switch scenePhase {
        case .active: .active
        case .inactive: .inactive
        case .background: .background
        @unknown default: .inactive
        }
    }
}

enum CompetitionScreenKind: Hashable {
    case invite(waitsOnThem: Bool), underway, result, closed
}

func competitionScreenKind(
    _ competition: LocalCompetitionPresentation,
    source: CompetitionPublicationSource?
) -> CompetitionScreenKind {
    switch competition.lifecycle {
    case .completed, .archived: .result
    case _ where competition.isPractice: .underway
    case .scheduled, .active, .endsToday, .tallying: .underway
    case let .pending(direction, _, _):
        .invite(waitsOnThem: source == .remoteParticipants && direction == .outgoing)
    case .declined, .expired, .cancelled: .closed
    }
}

private struct CompetitionClosedChallengeView: View {
    let competition: LocalCompetitionPresentation
    let canChallengeAgain: Bool
    let isInFlight: Bool
    let challengeAgain: () -> Void

    @Environment(\.locale) private var locale
    @Environment(\.timeZone) private var timeZone

    var body: some View {
        let text = competitionClosedChallengeText(
            competition, locale: locale, timeZone: timeZone
        )
        let isCancelledMatch = if case .cancelled = competition.lifecycle { true } else { false }
        ContentUnavailableView {
            Label(
                text?.title ?? competition.opponentDisplayName,
                systemImage: isCancelledMatch
                    ? "calendar.badge.minus" : "person.crop.circle.badge.xmark"
            )
        } description: {
            if isCancelledMatch {
                Text("\(competition.opponentDisplayName) cancelled it before it started. Nothing was recorded.")
            } else if let line = text?.line {
                Text("\(line).")
            }
        } actions: {
            if competitionIsClosedOutgoing(competition.lifecycle), canChallengeAgain {
                Button(action: challengeAgain) {
                    BusyLabel("Challenge \(competition.opponentDisplayName) Again", isBusy: isInFlight)
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(isInFlight)
                .accessibilityIdentifier("competition.closed.again")
            }
        }
        .background(Theme.ground)
        .navigationTitle(competition.opponentDisplayName)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("competition.closed")
    }
}

private struct DrawerInteractivePop: UIViewControllerRepresentable {
    let isEnabled: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> UIViewController {
        UIViewController()
    }

    func updateUIViewController(_ controller: UIViewController, context: Context) {
        context.coordinator.isEnabled = isEnabled
        Task { @MainActor in
            guard let nav = controller.navigationController,
                  let pop = nav.interactivePopGestureRecognizer else { return }
            if pop.delegate !== context.coordinator {
                pop.delegate = context.coordinator
            }
            pop.isEnabled = isEnabled
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var isEnabled = false

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            isEnabled
        }
    }
}
