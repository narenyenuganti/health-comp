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
                    continueTapped: { store.send(.onboardingContinueTapped) },
                    notNowTapped: { store.send(.onboardingNotNowTapped) }
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
                accept: { store.send(.acceptClaimTapped) },
                decline: { store.send(.declineClaimTapped) },
                retry: { store.send(.retryClaimTapped) },
                dismiss: { store.send(.dismissClaimStatus) }
            )
        }
    }

    private var home: some View {
        NavigationStack(
            path: CompetitionHomeRoute.stack(
                path: navigationPath,
                showsHistory: Binding(
                    get: { store.showsHistory },
                    set: { store.send(.historyPresentationChanged($0)) }
                )
            )
        ) {
            Group {
                if let publication = store.competition.publication {
                    CompetitionSharingView(
                        publication: publication,
                        inviteCreationStatus: store.competition
                            .inviteCreationRematchParentID == nil
                                ? store.competition.inviteCreationStatus
                                : .idle,
                        createdInviteLink: store.competition
                            .inviteCreationRematchParentID == nil
                                ? store.competition.createdInviteLink
                                : nil,
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
                        retry: retry
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
                case let .competition(id):
                    destination(for: id)
                        .toolbarRole(.editor)
                }
            }
        }
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
                case .ready:
                    store.send(.declineClaimTapped)
                case .retryable:
                    store.send(.dismissRetryableClaim)
                case .unavailable:
                    store.send(.dismissClaimStatus)
                case .confirmationTimedOut:
                    store.send(.dismissClaimStatus)
                case .idle, .claiming, .waitingForCompetition:
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
           ) {
            switch competition.lifecycle {
            case .pending:
                CompetitionInviteView(
                    competition: competition,
                    source: publication.source,
                    isCommandInFlight: store.competition
                        .isCommandInFlight(id),
                    send: sendCompetitionAction
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
                    }
                )

            case .completed, .archived:
                CompetitionResultView(
                    competition: competition,
                    awards: publication.dashboard.awards,
                    source: publication.source,
                    inviteCreationStatus: store.competition
                        .inviteCreationRematchParentID == id
                            ? store.competition.inviteCreationStatus
                            : .idle,
                    createdInviteLink: store.competition
                        .inviteCreationRematchParentID == id
                            ? store.competition.createdInviteLink
                            : nil,
                    isCommandInFlight: store.competition
                        .isCommandInFlight(id),
                    send: sendCompetitionAction,
                    muteButton: muteButton(for: competition),
                    issue: competitionRowIssue(id, in: publication.dashboard.issues),
                    retry: retry
                )

            case .declined, .expired:
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
            saveFailed: store.competition.notificationPreferenceSaveFailed,
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
        ContentUnavailableView {
            Label(
                text?.title ?? competition.opponentDisplayName,
                systemImage: "person.crop.circle.badge.xmark"
            )
        } description: {
            if let line = text?.line {
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
