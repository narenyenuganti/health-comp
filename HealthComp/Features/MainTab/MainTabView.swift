import CompetitionCore
import ComposableArchitecture
import Foundation
import SwiftUI

struct MainTabView: View {
    let store: StoreOf<MainTabFeature>
    /// Shows the avatar that opens Account. Test Lab hosts omit it.
    var openAccount: (() -> Void)?

    @Environment(\.scenePhase) private var scenePhase
    @State private var isChallengePresented = false
    /// New Match: the format picker, whose Duel opens the Challenge sheet.
    @State private var isNewMatchPresented = false
    @State private var opensDuel = false
    @State private var isPracticePresented = false
    @State private var isVersusPlaying = false
    @State private var replaysVersus = false
    @State private var recapPeriod: CompetitionRecapPeriod?

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
        // Loaded up front, so a person page rarely opens on the ledger
        // it shows until your block list is known.
        .task(id: store.competition.publication?.source == .remoteParticipants) {
            if store.competition.publication?.source == .remoteParticipants {
                store.send(.competition(.blockedPeopleRequested))
                store.send(.competition(.friends(.requested)))
            }
        }
        .onChange(of: scenePhase) { _, newValue in
            store.send(.scenePhaseChanged(Self.sceneState(newValue)))
            // A photo changed or hidden while away shows without a relaunch.
            if newValue == .active {
                store.send(.competition(.profilePhotosNeeded(photoOwners)))
                if store.competition.publication?.source == .remoteParticipants {
                    store.send(.competition(.friends(.requested)))
                }
            }
        }
        // Keeps the notifications prompt from presenting under the
        // Challenge or practice sheet or the recap deck, where SwiftUI would
        // drop it, or over the versus intro.
        .onChange(of: isChallengePresented || isNewMatchPresented || isPracticePresented || isVersusPlaying || recapPeriod != nil) { _, isOpen in
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
                now: store.inviteClaimPreviewEvaluatedAt ?? Date(),
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
            // After this sheet is gone, so the Challenge sheet can present.
            if opensDuel { opensDuel = false; isChallengePresented = true }
        }) {
            GroupMatchCreateView(
                store: store.scope(state: \.competition.group, action: \.competition.group),
                people: newMatchPeople,
                onDuel: { opensDuel = true; isNewMatchPresented = false }
            )
        }
        // A Friends push opens Friends in front of everything.
        .onChange(of: store.friendsRouteCount) { _, _ in
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
        // Here, because both sheets can close without drawing the outcome.
        // A timeout reaches `.idle` too, so the open match is the proof.
        .sensoryFeedback(.success, trigger: isSheetLanding) { old, new in
            old && !new && !store.path.isEmpty
                && store.inviteClaimStatus == .idle && store.challengeFromLink == nil
        }
        // Last, so every screen and sheet above draws the same photos.
        .environment(\.profilePhotos, store.competition.profilePhotoImages)
    }

    /// Friends, then people you've had a duel with, once each.
    private var newMatchPeople: [GroupMatchPlayer] {
        let friends = (store.competition.friends.list?.friends ?? []).map {
            GroupMatchPlayer(profileID: $0.id, name: $0.displayName)
        }
        let played = (store.competition.publication?.dashboard.competitions ?? []).compactMap { competition in
            RemoteCompetitionOpponentIdentity.profileID(competition.opponentIdentity).map {
                GroupMatchPlayer(profileID: $0, name: competition.opponentDisplayName)
            }
        }
        var seen = Set<UUID>()
        return (friends + played).filter { seen.insert($0.profileID).inserted }
    }

    private var photoOwners: [UUID] {
        store.competition.photoOwners(claimSender: store.inviteClaimPreview?.sender.id)
    }

    /// Accept, or Send from a link: both end by closing the sheet on the match.
    private var isSheetLanding: Bool {
        if store.inviteClaimStatus == .claiming
            || store.inviteClaimStatus == .waitingForCompetition {
            return true
        }
        guard store.challengeFromLink != nil else { return false }
        return store.competition.challengeSheetStatus == .creating
            || store.competition.challengeSheetStatus.controlPhase == .sent
    }

    /// A lifecycle change while the screen is open crossfades in place. The
    /// result keeps its cut, because its own reveal is the transition.
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
            // Home lays out finished under the loader, which fades off it.
            ZStack {
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
                        findRecipient: { store.send(.competition(.findInviteRecipientTapped)) },
                        createInvite: {
                            store.send(.competition(.createInviteTapped))
                        },
                        isChallengePresented: $isChallengePresented,
                        friends: store.competition.friends.list?.friends ?? [],
                        chooseFriend: { friend in
                            store.send(.competition(.challengeRecipientChosen(.init(
                                AuthenticatedProfile(id: friend.id, displayName: friend.displayName)
                            ))))
                        },
                        searchPeople: {
                            isChallengePresented = false
                            store.send(.competition(.friends(.searchFocusRequested(true))))
                            store.send(.friendsPresentationChanged(true))
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
                        openRecap: { recapPeriod = $0 }
                    )
                    .transition(.identity)
                } else {
                    AppProgressView(title: "Loading matches…")
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                        .transition(.opacity)
                        .zIndex(1)
                }
            }
            .animation(Motion.fade, value: store.competition.publication == nil)
            .toolbar { homeToolbar }
            // Outside Home's `.refreshable`, which a sheet presented from
            // inside it inherits: a drag down would refresh, not close.
            .sheet(isPresented: $isPracticePresented) {
                if let publication = store.competition.publication,
                   let practice = practiceStart(publication) {
                    PracticeMatchSheet(practice: practice)
                }
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
                case let .records(identity):
                    if let publication = store.competition.publication {
                        CompetitionRecordsView(publication: publication, opponentIdentity: identity)
                            .toolbarRole(.editor)
                    }
                case let .competition(id):
                    competitionScreen(id)
                        .toolbarRole(.editor)
                        // Here, as this outlives the swap to the result: the
                        // swap moves no focus, and a push never reaches this.
                        .onChange(of: completedResultTitle(id)) { old, title in
                            if old == nil, let title {
                                AccessibilityNotification.Announcement(title).post()
                            }
                        }
                }
            }
        }
        // Here, not on the root Group, so it doesn't share a view with the
        // claim sheet.
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

    /// The person page, with the match under it on the stack, whether you
    /// blocked them, and their mute. Someone with no finished match gets
    /// their small page, when search or Friends has told us who they are.
    @ViewBuilder
    private func personScreen(
        _ identity: String,
        publication: LocalCompetitionPublication
    ) -> some View {
        if let id = RemoteCompetitionOpponentIdentity.profileID(identity),
           let person = store.competition.friends.people[id],
           competitionRivalryWeeks(publication.dashboard.competitions, opponentIdentity: identity).isEmpty {
            FriendProfileView(
                controls: friendControls(id, displayName: person.displayName),
                isBlocked: store.competition.blockedPeople.map { $0.contains { $0.id == id } },
                unblock: { store.send(.competition(.unblockTapped(id))) },
                challenge: {
                    store.send(.competition(.challengeRecipientChosen(.init(
                        AuthenticatedProfile(id: id, displayName: person.displayName)
                    ))))
                    isChallengePresented = true
                },
                hasPlayed: publication.dashboard.competitions.contains { $0.opponentIdentity == identity }
            )
        } else {
            matchedPersonScreen(identity, publication: publication)
        }
    }

    private func matchedPersonScreen(
        _ identity: String,
        publication: LocalCompetitionPublication
    ) -> some View {
        let depth = store.personPlace.depth
        let profileID = RemoteCompetitionOpponentIdentity.profileID(identity)
        // Unknown (nil) until your block list loads, so someone you blocked
        // never shows more than the ledger.
        let isBlocked: Bool? = if let profileID, publication.source == .remoteParticipants {
            store.competition.blockedPeople.map { $0.contains { $0.id == profileID } }
        } else {
            false
        }
        return CompetitionPersonView(
            publication: publication,
            opponentIdentity: identity,
            cameFrom: depth > 0 && depth <= store.path.count ? store.path[depth - 1] : nil,
            isBlocked: isBlocked,
            unblock: profileID.map { id in { store.send(.competition(.unblockTapped(id))) } },
            muteButton: publication.dashboard.competitions
                .first { $0.opponentIdentity == identity }
                .flatMap(muteButton(for:)),
            challenge: challengeAgain,
            friend: profileID.flatMap { id in
                guard publication.source == .remoteParticipants,
                      let name = publication.dashboard.competitions
                        .first(where: { $0.opponentIdentity == identity })?.opponentDisplayName
                else { return nil }
                return friendControls(id, displayName: name)
            }
        )
        // Your own blocks only; the phone never learns who blocked you.
        .task(id: identity) {
            if publication.source == .remoteParticipants {
                store.send(.competition(.blockedPeopleRequested))
            }
        }
    }

    /// Friending, Block and Report for one person, as the Friends reducer
    /// has them. Someone it hasn't seen is nobody to you once the list loads.
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

    /// "Your record with Sam" on a match: pushes their page, or pops back to
    /// it when it's already on the stack.
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
        ToolbarItem(placement: .topBarLeading) {
            BrandMark().frame(height: 26)
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            // Invitations are private links between real people.
            if store.competition.publication?.source == .remoteParticipants {
                FriendsToolbarButton(requestCount: store.competition.friends.requestCount) {
                    store.send(.friendsPresentationChanged(true))
                }
                CompetitionChallengeButton {
                    if GroupMatchRollout.showsFormatPicker { isNewMatchPresented = true } else { isChallengePresented = true }
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

    /// The fixture reinvites Alex; a real match prefills the Challenge sheet
    /// with the same account, and Create still sends it.
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

    /// Nil until that match finishes.
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
                store: store.scope(state: \.competition.group, action: \.competition.group)
            )
            .environment(
                \.groupMatchReplayIntro,
                CompetitionVersusIntroGate.isEnabled
                    && store.competition.publication.flatMap {
                        groupMatchVersusIntroContent(match, source: $0.source, isReplay: true)
                    } != nil
                    ? { replaysVersus = true } : nil
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
                    // An unstructured task, so leaving the screen mid-refresh
                    // doesn't cancel the reconcile.
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
                    // The real-match gate: never on the simulated fixture.
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
                    howItWasWon: competitionHowItWasWon(
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
            // ponytail: popping after the match left (End Practice, a server
            // delete) slides off blank, not "Match Unavailable"; cache the
            // last screen if the blank shows.
            Theme.ground.ignoresSafeArea()
        } else {
            ContentUnavailableView(
                "Match Unavailable",
                systemImage: "exclamationmark.circle",
                description: Text("Go back to Home to refresh this match.")
            )
        }
    }

    /// Practice: simulated on its match screen (the rules say so), no mute,
    /// no Cancel Match, End Practice in the menu; its result's one action is
    /// Challenge Someone.
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
        return CompetitionPracticeStart(
            isStarting: store.competition.isCommandInFlight(PracticeMatch.startCommandID),
            failed: publication.dashboard.issues.contains(
                .commandRejected(PracticeMatch.startCommandID)
            ),
            start: { store.send(.competition(.practiceStartTapped($0))) }
        )
    }

    private func sendCompetitionAction(_ action: CompetitionFeature.Action) {
        store.send(.competition(action))
    }

    /// Real matches only: never on the simulated fixture.
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

/// Which screen `destination(for:)` draws. `waitsOnThem` is a real challenge
/// you sent: it can only change because they answered.
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

/// A challenge that closed while its screen was open, drawn in place. After
/// a day the match leaves the dashboard and the screen pops.
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
