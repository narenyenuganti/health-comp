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

    var body: some View {
        Group {
            if let onboarding = store.onboarding {
                PermissionOnboardingView(
                    step: onboarding.step,
                    isRequesting: onboarding.isRequesting,
                    isForChallenge: store.acceptsClaimOnStart,
                    continueTapped: { store.send(.onboardingContinueTapped) },
                    notNowTapped: {}
                )
            } else {
                home
            }
        }
        .task {
            await store.send(.task).finish()
        }
        .onChange(of: scenePhase) { _, newValue in
            store.send(.scenePhaseChanged(Self.sceneState(newValue)))
        }
        // Keeps the notifications prompt from presenting under the
        // Challenge sheet, where SwiftUI would drop it.
        .onChange(of: isChallengePresented) { _, isOpen in
            store.send(.challengeSheetVisibilityChanged(isOpen))
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: Notification.Name.NSSystemTimeZoneDidChange
            )
        ) { _ in
            store.send(.timeZoneChanged)
        }
        .sheet(isPresented: claimSheetPresented) {
            ClaimCompetitionView(
                status: store.inviteClaimStatus,
                preview: store.inviteClaimPreview,
                now: store.inviteClaimPreviewEvaluatedAt ?? Date(),
                hasQueuedChallenge: store.queuedClaimRoute != nil,
                declineFailed: store.claimDeclineFailed,
                accept: { store.send(.acceptClaimTapped) },
                notNow: { store.send(.notNowClaimTapped) },
                decline: { store.send(.declineClaimConfirmed) },
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
        .onChange(of: isChallengePresented) { _, isPresented in
            if isPresented, store.competition.publication?.source == .remoteParticipants {
                store.send(.competition(.challengeLinkRequested))
            }
        }
    }

    private var home: some View {
        NavigationStack(
            path: CompetitionHomeRoute.stack(
                path: navigationPath,
                showsHistory: Binding(
                    get: { store.showsHistory },
                    set: { store.send(.historyPresentationChanged($0)) }
                ),
                person: Binding(
                    get: { store.historyPersonIdentity },
                    set: { store.send(.historyPersonChanged($0)) }
                )
            )
        ) {
            Group {
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
                        practice: publication.source == .remoteParticipants
                            ? CompetitionPracticeStart(
                                isStarting: store.competition.isCommandInFlight(
                                    PracticeMatch.startCommandID
                                ),
                                failed: publication.dashboard.issues.contains(
                                    .commandRejected(PracticeMatch.startCommandID)
                                ),
                                start: { store.send(.competition(.practiceStartTapped($0))) }
                            )
                            : nil
                    )
                    .refreshable {
                        await store.send(.competition(.pullToRefresh)).finish()
                    }
                } else {
                    ProgressView("Loading matches…")
                        .foregroundStyle(Theme.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Theme.ground)
                }
            }
            .toolbar { homeToolbar }
            .navigationDestination(for: CompetitionHomeRoute.self) { route in
                switch route {
                case .history:
                    if let publication = store.competition.publication {
                        CompetitionHistoryView(publication: publication)
                            .toolbarRole(.editor)
                    }
                case let .person(identity):
                    if let publication = store.competition.publication {
                        CompetitionPersonView(
                            publication: publication,
                            opponentIdentity: identity
                        )
                        .toolbarRole(.editor)
                    }
                case let .competition(id):
                    destination(for: id)
                        .toolbarRole(.editor)
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
                CompetitionChallengeButton { isChallengePresented = true }
            }
            if let openAccount {
                Button(action: openAccount) {
                    Group {
                        if let accountInitial {
                            Text(accountInitial)
                                .font(.headline.width(.condensed))
                                .foregroundStyle(Theme.you)
                        } else {
                            Image(systemName: "person.fill")
                                .foregroundStyle(Theme.ink)
                        }
                    }
                    .frame(width: 34, height: 34)
                    .background(Theme.control, in: Circle())
                }
                .accessibilityLabel("Account")
                .accessibilityIdentifier("app.account")
            }
        }
    }

    private var accountInitial: String? {
        store.competition.ownProfile?.displayName.first.map { String($0).uppercased() }
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

    @ViewBuilder
    private func destination(for id: CompetitionID) -> some View {
        if let publication = store.competition.publication,
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
                    commandFailed: publication.dashboard.issues.contains(.commandRejected(id))
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
                        : nil
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
                    retry: retry
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

    private func sendCompetitionAction(_ action: CompetitionFeature.Action) {
        store.send(.competition(action))
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
                    if isInFlight {
                        ProgressView()
                    } else {
                        Text("Challenge \(competition.opponentDisplayName) Again")
                    }
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
